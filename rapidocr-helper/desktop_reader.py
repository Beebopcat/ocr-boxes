"""Per-OCR-Boxes CPU helper for explicitly selected general-purpose regions.

No screen grabbing, game/Luna policy changes, downloads, or GPU inference. The
private bootstrap and owned bitmap directory belong to one parent process.
"""
import argparse
import base64
import ctypes
import hmac
import json
import os
from pathlib import Path
import re
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image
from cpu_runtime import LazyRapidEngine

class Rejected(ValueError):
    pass

class Owner:
    def __init__(self, config, engine=None, player=None, render=None):
        self.parent = int(config["parent"])
        self.token = config["token"]
        if not re.fullmatch(r"[0-9a-f]{64}", self.token):
            raise Rejected("Invalid bootstrap")
        self.root = Path(config["root"]).resolve(strict=True)
        self.engine = engine or LazyRapidEngine(Path(__file__).with_name("cpu-runtime.json"))
        self.lock = threading.RLock()
        self.ocr_lock = threading.Lock()
        self.epoch = -1
        self.speech_seq = 0
        self.play_lock = threading.Lock()
        self.paused = False
        self.pending = None
        self.work = threading.Condition(self.lock)
        self.busy = False
        self.error = ""
        self.cancel = threading.Event()
        self.player = player
        self.render = render or self._render
        threading.Thread(target=self._worker,daemon=True).start()

    def authenticate(self, req):
        if not isinstance(req, dict) or not isinstance(req.get("token"), str) or not hmac.compare_digest(req["token"], self.token):
            raise Rejected("Unauthorized local client")

    def advance(self, epoch):
        if type(epoch) is not int or not 0 <= epoch < 2**53:
            raise Rejected("Invalid request generation")
        with self.lock:
            if epoch < self.epoch:
                raise Rejected("Stale request generation")
            self.epoch = epoch

    def snapshot(self, path):
        if not isinstance(path, str):
            raise Rejected("Owned bitmap required")
        image = Path(path)
        if not image.is_absolute() or image.suffix.lower() != ".bmp" or not re.fullmatch(r"ocrbox-v2-"+str(self.parent)+r"-\d+-box[1-4]\.bmp",image.name):
            raise Rejected("Owned bitmap required")
        resolved = image.resolve(strict=True)
        if resolved.parent != self.root or image.is_symlink():
            raise Rejected("Bitmap is outside this reader")
        if resolved.stat().st_size > 128*1024*1024:
            raise Rejected("Bitmap too large")
        return resolved

    def ocr(self, req):
        self.advance(req.get("epoch"))
        image_path = self.snapshot(req.get("image"))
        epoch = req["epoch"]
        with self.ocr_lock:
            with self.lock:
                if epoch != self.epoch:
                    raise Rejected("Stale OCR")
            with Image.open(image_path) as source:
                if source.format != "BMP" or not 8 <= source.width <= 8000 or not 8 <= source.height <= 8000 or source.width*source.height > 32_000_000:
                    raise Rejected("Invalid bitmap dimensions")
                image = np.asarray(source.convert("RGB"))[:,:,::-1]
            result, _ = self.engine.run(image)
            with self.lock:
                if epoch != self.epoch:
                    raise Rejected("Stale OCR")
            # Preserve OCR's row order, joining fragments on the same text line.
            entries = [(min(p[1] for p in box), min(p[0] for p in box), str(text)) for box,text,score in (result or [])]
            entries.sort(key=lambda item:(round(item[0]/12),item[1]))
            return {"ok":True,"text":" ".join(item[2] for item in entries),"epoch":epoch}

    @staticmethod
    def _render(text, voice, speed, request_id):
        request = urllib.request.Request("http://127.0.0.1:8787/render-voice",
            data=json.dumps({"requestId":request_id,"text":text,"voice":voice,"speed":speed}).encode(),
            headers={"Content-Type":"application/json"})
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=90) as response:
            raw = response.read(24*1024*1024+1)
        if len(raw)>24*1024*1024:
            raise Rejected("Rendered audio too large")
        result = json.loads(raw)
        if not isinstance(result,dict) or result.get("completed") is not True or result.get("renderOnly") is not True or result.get("requestId") != request_id or result.get("profileId") != voice or result.get("sampleRate") != 24000 or result.get("channels") != 1 or result.get("dtype") != "float32-le":
            raise Rejected("Unexpected voice render response")
        frames = result.get("frames")
        if type(frames) is not int or not 0 < frames <= 24000*120:
            raise Rejected("Invalid audio duration")
        pcm = base64.b64decode(result["pcm"],validate=True)
        if len(pcm) != frames*4:
            raise Rejected("Truncated audio")
        samples = np.frombuffer(pcm,dtype="<f4")
        if not np.isfinite(samples).all():
            raise Rejected("Invalid audio samples")
        return (np.clip(samples,-1,1)*32767).astype("<i2").tobytes(), 24000

    def speech(self, action, req):
        sequence=req.get("seq")
        if type(sequence) is not int or not 0 < sequence < 2**53:
            raise Rejected("Invalid speech command")
        with self.lock:
            if sequence <= self.speech_seq:
                raise Rejected("Stale speech command")
            self.speech_seq=sequence
            if action == "start":
                text,voice,speed=req.get("text"),req.get("voice"),req.get("speed",1)
                if not isinstance(text,str) or not text.strip() or len(text)>200000 or not isinstance(voice,str) or not re.fullmatch(r"[a-z0-9_]{1,64}",voice) or type(speed) not in (int,float) or not 0.5<=speed<=2 or (voice.startswith("qn_") and speed!=1):
                    raise Rejected("Invalid speech request")
                self.cancel.set()
                cancel=threading.Event()
                self.cancel=cancel
                self.busy=True
                self.error=""
                self.paused=False
                self.pending=(text,voice,speed,sequence,cancel)
                self.work.notify()
            elif action == "stop":
                self.cancel.set()
                self.pending=None
                self.busy=False
                if self.player:
                    self.player.pause(False)
            elif action in ("pause","resume"):
                self.paused=action=="pause"
                if self.player:
                    self.player.pause(self.paused)
            else:
                raise Rejected("Unknown speech command")
        return {"ok":True,"seq":sequence}

    def _worker(self):
        # One renderer per reader. Replacements coalesce instead of spawning CPU work.
        while True:
            with self.work:
                self.work.wait_for(lambda:self.pending is not None)
                job,self.pending=self.pending,None
            self._speak(*job)

    @staticmethod
    def chunks(text):
        while text:
            if len(text)<=600:
                yield text
                return
            end=text.rfind(" ",0,601)
            if end<200:end=600
            yield text[:end]
            text=text[end:].lstrip()

    def _speak(self,text,voice,speed,sequence,cancel):
        try:
            for chunk in self.chunks(text):
                if cancel.is_set():
                    return
                pcm,rate=self.render(chunk,voice,speed,"ocrboxes-"+uuid.uuid4().hex)
                if cancel.is_set():
                    return
                with self.lock:
                    if self.player is None:
                        from audio_output import WaveOutput
                        self.player=WaveOutput()
                    player=self.player
                with self.play_lock:
                    if cancel.is_set():
                        return
                    with self.lock:
                        player.pause(self.paused)
                    player.play(pcm,rate,cancel)
        except Exception as error:
            with self.lock:
                if self.cancel is cancel:
                    self.error="Speech output failed ("+type(error).__name__+"). Check the selected output or local voice service."
        finally:
            with self.lock:
                if self.cancel is cancel:
                    self.busy=False

    def status(self):
        with self.lock:
            target = getattr(self.player,"target",None)
            return {"ok":True,"speaking":self.busy,"error":self.error,"seq":self.speech_seq,"output":target}

def handler(owner):
    class H(BaseHTTPRequestHandler):
        def log_message(self,*args):
            pass # never log screenshots, text, tokens or request bodies
        def send(self,code,data):
            payload=json.dumps(data).encode()
            self.send_response(code)
            self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(payload)))
            self.end_headers()
            try:self.wfile.write(payload)
            except (BrokenPipeError,ConnectionResetError):pass
        def do_POST(self):
            try:
                if self.client_address[0] != "127.0.0.1" or self.headers.get("Origin") or self.headers.get("Host") != "127.0.0.1:"+str(self.server.server_port) or self.headers.get("Transfer-Encoding") or self.headers.get("Content-Type","").split(";")[0].lower()!="application/json":
                    raise Rejected("Local owner required")
                lengths=self.headers.get_all("Content-Length",[])
                limit=2*1024*1024 if self.path=="/tts/start" else 65536
                if len(lengths)!=1 or not lengths[0].isdigit() or not 0<int(lengths[0])<=limit:
                    raise Rejected("Invalid body size")
                self.connection.settimeout(5)
                req=json.loads(self.rfile.read(int(lengths[0])))
                owner.authenticate(req)
                if self.path=="/health":
                    self.send(200,{"ok":True,"protocol":"desktop-reader-v1","ocr":owner.engine.health()})
                elif self.path=="/ocr":self.send(200,owner.ocr(req))
                elif self.path=="/ocr/stop":
                    owner.advance(req.get("epoch"))
                    self.send(200,{"ok":True})
                elif self.path=="/tts/status":self.send(200,owner.status())
                elif self.path.startswith("/tts/"):self.send(200,owner.speech(self.path[5:],req))
                else:self.send(404,{"ok":False,"error":"Unknown command"})
            except (Rejected,ValueError,KeyError,TypeError,OSError):
                self.send(409,{"ok":False,"error":"Invalid, unavailable or stale reader request"})
            except Exception:
                self.send(500,{"ok":False,"error":"Reader processing failed"})
    return H

def watch_parent(pid):
    kernel=ctypes.WinDLL("kernel32")
    kernel.OpenProcess.argtypes=[ctypes.c_ulong,ctypes.c_int,ctypes.c_ulong]
    kernel.OpenProcess.restype=ctypes.c_void_p
    kernel.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
    handle=kernel.OpenProcess(0x100000,0,pid)
    if not handle:os._exit(0)
    while kernel.WaitForSingleObject(handle,1000)==0x102:pass
    os._exit(0)

if __name__=="__main__":
    args=argparse.ArgumentParser()
    args.add_argument("--bootstrap",required=True)
    config=json.loads(Path(args.parse_args().bootstrap).read_text(encoding="utf-8-sig"))
    owner=Owner(config)
    server=ThreadingHTTPServer(("127.0.0.1",0),handler(owner))
    threading.Thread(target=watch_parent,args=(owner.parent,),daemon=True).start()
    ready=Path(config["ready"])
    ready.write_text(json.dumps({"port":server.server_port,"parent":owner.parent,"protocol":"desktop-reader-v1"}),encoding="utf-8")
    server.serve_forever()
