"""Lazy, CPU-only RapidOCR owner with truthful nonblocking health metadata."""
from __future__ import annotations
import copy
import json
import threading

def read_cpu_config(path):
    with open(path, "r", encoding="utf-8-sig") as stream:
        data = json.loads(stream.read(4097))
    if not isinstance(data, dict) or type(data.get("schema_version")) is not int or data.get("schema_version") != 1:
        raise ValueError("unsupported CPU runtime schema")
    intra, inter = data.get("intra_op_num_threads"), data.get("inter_op_num_threads")
    if type(intra) is not int or intra not in (2, 4, 8) or type(inter) is not int or inter != 1:
        raise ValueError("CPU threads must be intra=2/4/8 and inter=1")
    return intra, inter

def rapid_factory(**options):
    from rapidocr_onnxruntime import RapidOCR
    return RapidOCR(**options)

class LazyRapidEngine:
    def __init__(self, config_path, factory=rapid_factory, warm_image=None):
        self.factory, self.warm_image = factory, warm_image
        self._engine = None
        self._lock = threading.RLock()
        self._metadata_lock = threading.Lock()
        self._state = {"resident": False, "ready": False, "loading": False,
                       "providers": {}, "effective_threads": {}, "error": ""}
        try:
            self.intra, self.inter = read_cpu_config(config_path)
        except (OSError, ValueError, TypeError):
            self.intra, self.inter = None, None
            self._state["error"] = "invalid or unreadable CPU runtime configuration"

    def health(self):
        with self._metadata_lock:
            state = copy.deepcopy(self._state)
        state["configured_threads"] = {"intra_op": self.intra, "inter_op": self.inter}
        state["placement_policy"] = "CPUExecutionProvider only"
        return state

    def _update(self, **values):
        with self._metadata_lock:
            self._state.update(values)

    def ensure(self):
        with self._lock:
            if self._engine is not None:
                return self._engine
            if self.health()["error"]:
                raise RuntimeError("CPU OCR initialization unavailable; inspect health")
            self._update(loading=True)
            try:
                engine = self.factory(det_limit_side_len=480, det_limit_type="min",
                    det_use_cuda=False, cls_use_cuda=False, rec_use_cuda=False,
                    det_use_dml=False, cls_use_dml=False, rec_use_dml=False,
                    intra_op_num_threads=self.intra, inter_op_num_threads=self.inter)
                providers, threads = {}, {}
                for label, member, wrapper in (("detection", "text_det", "infer"),
                                               ("classification", "text_cls", "infer"),
                                               ("recognition", "text_rec", "session")):
                    session = getattr(getattr(engine, member), wrapper).session
                    providers[label] = list(session.get_providers())
                    opts = session.get_session_options()
                    threads[label] = {"intra_op": opts.intra_op_num_threads,
                                      "inter_op": opts.inter_op_num_threads}
                    if providers[label] != ["CPUExecutionProvider"]:
                        raise RuntimeError("non-CPU OCR provider rejected")
                    if threads[label] != {"intra_op": self.intra, "inter_op": self.inter}:
                        raise RuntimeError("effective OCR thread settings do not match configuration")
                if self.warm_image is None:
                    import numpy as np
                    image = np.zeros((64, 256, 3), np.uint8)
                else:
                    image = self.warm_image()
                engine(image)  # warm once, only when the first OCR request arrives
                self._engine = engine
                self._update(resident=True, ready=True, providers=providers,
                             effective_threads=threads, error="")
                return engine
            except Exception as exc:
                self._update(error="CPU OCR initialization failed (" + type(exc).__name__ + ")")
                raise RuntimeError("CPU OCR initialization failed; inspect health") from None
            finally:
                self._update(loading=False)

    def run(self, image):
        with self._lock:
            return self.ensure()(image)


