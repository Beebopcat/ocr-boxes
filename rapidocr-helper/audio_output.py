"""Resolve the current Windows default endpoint for each owned playback stream.

Uses Windows MMDevice/WinMM APIs only. Never changes system audio preferences.
"""
import ctypes as C
from ctypes import wintypes as W
import threading
import time
import uuid

class GUID(C.Structure):
    _fields_ = [("bytes", C.c_ubyte * 16)]
    def __init__(self, value):
        super().__init__()
        C.memmove(C.byref(self), uuid.UUID(value).bytes_le, 16)

def _method(ptr, index, result, *args):
    return C.WINFUNCTYPE(result, C.c_void_p, *args)(C.cast(ptr, C.POINTER(C.POINTER(C.c_void_p))).contents[index])

def default_endpoint():
    ole = C.OleDLL("ole32")
    ole.CoInitializeEx.argtypes = [C.c_void_p, W.DWORD]
    hr = ole.CoInitializeEx(None, 0)
    initialized = hr in (0, 1)
    enum = C.c_void_p()
    device = C.c_void_p()
    store = C.c_void_p()
    identity = C.c_void_p()
    variant = C.create_string_buffer(24)
    try:
        cls = GUID("BCDE0395-E52F-467C-8E3D-C4579291692E")
        iid = GUID("A95664D2-9614-4F35-A746-DE8DB63617E6")
        ole.CoCreateInstance.argtypes = [C.POINTER(GUID), C.c_void_p, W.DWORD, C.POINTER(GUID), C.POINTER(C.c_void_p)]
        if ole.CoCreateInstance(C.byref(cls), None, 1, C.byref(iid), C.byref(enum)) < 0:
            raise OSError("Cannot enumerate audio endpoints")
        if _method(enum, 4, C.c_long, C.c_int, C.c_int, C.POINTER(C.c_void_p))(enum, 0, 1, C.byref(device)) < 0:
            raise OSError("No default playback endpoint")
        if _method(device, 5, C.c_long, C.POINTER(C.c_void_p))(device, C.byref(identity)) < 0:
            raise OSError("Cannot identify default playback endpoint")
        endpoint_id = C.wstring_at(identity)
        if _method(device, 4, C.c_long, W.DWORD, C.POINTER(C.c_void_p))(device, 0, C.byref(store)) < 0:
            raise OSError("Cannot read playback endpoint")
        # PKEY_Device_FriendlyName: {a45c254e-df1c-4efd-8020-67d146a850e0}, 14.
        key = C.create_string_buffer(20)
        guid = GUID("A45C254E-DF1C-4EFD-8020-67D146A850E0")
        C.memmove(key, C.byref(guid), 16)
        C.c_ulong.from_buffer(key, 16).value = 14
        if _method(store, 5, C.c_long, C.c_void_p, C.c_void_p)(store, key, variant) < 0 or C.c_ushort.from_buffer(variant).value != 31:
            raise OSError("Cannot read playback endpoint name")
        name = C.wstring_at(C.c_void_p.from_buffer(variant, 8).value)
        return {"id": endpoint_id, "name": name}
    finally:
        ole.PropVariantClear(C.byref(variant))
        if identity:
            ole.CoTaskMemFree.argtypes = [C.c_void_p]
            ole.CoTaskMemFree(identity)
        for ptr in (store, device, enum):
            if ptr:
                _method(ptr, 2, W.ULONG)(ptr)
        if initialized:
            ole.CoUninitialize()

class WAVEOUTCAPS(C.Structure):
    _fields_ = [("mid", W.WORD), ("pid", W.WORD), ("version", W.DWORD),
                ("name", W.WCHAR * 32), ("formats", W.DWORD),
                ("channels", W.WORD), ("reserved", W.WORD), ("support", W.DWORD)]

def output_device():
    endpoint = default_endpoint()
    api = C.WinDLL("winmm")
    matches = []
    for index in range(api.waveOutGetNumDevs()):
        caps = WAVEOUTCAPS()
        if api.waveOutGetDevCapsW(index, C.byref(caps), C.sizeof(caps)) == 0 and caps.name == endpoint["name"][:31]:
            matches.append(index)
    if len(matches) != 1:
        raise OSError("Default endpoint has no unique WinMM output; refusing speaker fallback")
    return {**endpoint, "device": matches[0]}

class WaveOutput:
    def __init__(self):
        self.pause_event = threading.Event()
        self.target = None

    def pause(self, value):
        if value:
            self.pause_event.set()
        else:
            self.pause_event.clear()

    def play(self, pcm, rate, cancel):
        api = C.WinDLL("winmm")
        class FORMAT(C.Structure):
            _fields_ = [("tag",W.WORD),("channels",W.WORD),("rate",W.DWORD),("bytes_sec",W.DWORD),("align",W.WORD),("bits",W.WORD),("extra",W.WORD)]
        class HEADER(C.Structure):
            _fields_ = [("data",C.c_void_p),("length",W.DWORD),("recorded",W.DWORD),("user",C.c_size_t),("flags",W.DWORD),("loops",W.DWORD),("next",C.c_void_p),("reserved",C.c_size_t)]
        target = output_device()
        handle = C.c_void_p()
        fmt = FORMAT(1,1,rate,rate*2,2,16,0)
        api.waveOutOpen.argtypes = [C.POINTER(C.c_void_p), W.UINT, C.POINTER(FORMAT), C.c_size_t, C.c_size_t, W.DWORD]
        for name in ("waveOutPrepareHeader", "waveOutWrite", "waveOutUnprepareHeader"):
            getattr(api,name).argtypes = [C.c_void_p,C.POINTER(HEADER),W.UINT]
        for name in ("waveOutReset","waveOutPause","waveOutRestart","waveOutClose"):
            getattr(api,name).argtypes = [C.c_void_p]
        if api.waveOutOpen(C.byref(handle),target["device"],C.byref(fmt),0,0,0):
            raise OSError("Selected output cannot open")
        prepared = False
        data = C.create_string_buffer(pcm)
        header = HEADER(C.cast(data,C.c_void_p),len(pcm),0,0,0,0,None,0)
        self.target = target
        try:
            if cancel.is_set():
                return
            if api.waveOutPrepareHeader(handle,C.byref(header),C.sizeof(header)):
                raise OSError("Cannot prepare owned playback")
            prepared = True
            paused = False
            if self.pause_event.is_set():
                if api.waveOutPause(handle):
                    raise OSError("Cannot pause owned playback")
                paused = True
            if api.waveOutWrite(handle,C.byref(header),C.sizeof(header)):
                raise OSError("Cannot queue owned playback")
            checked = time.monotonic()
            while not header.flags & 1:
                if cancel.wait(0.03):
                    break
                wanted = self.pause_event.is_set()
                if wanted != paused:
                    if (api.waveOutPause if wanted else api.waveOutRestart)(handle):
                        raise OSError("Cannot control owned playback")
                    paused = wanted
                if time.monotonic()-checked > 0.4:
                    if default_endpoint()["id"] != target["id"]:
                        raise OSError("Default output changed; playback stopped. Read again on the new output.")
                    checked = time.monotonic()
        finally:
            api.waveOutReset(handle)
            if prepared:
                api.waveOutUnprepareHeader(handle,C.byref(header),C.sizeof(header))
            api.waveOutClose(handle)
