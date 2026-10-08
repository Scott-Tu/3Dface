#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
LAM 單張照片 → 3D 頭像 → 多角度渲染 API 伺服器（給 iPhone App 呼叫）

放在 LAM repo 根目錄執行：python lam_server.py
單次執行：python lam_server.py --once 照片.jpg 參數.json 輸出資料夾

環境變數（全部可選）：
  LAM_API_KEY          API 金鑰；空字串代表不檢查（不建議）
  LAM_PORT             監聽埠，預設 8000
  LAM_WORK_DIR         工作目錄，預設 ./lam_jobs
  LAM_MAX_JOBS         保留的工作數量，超過會刪除最舊的，預設 20
  LAM_DEFAULT_PARAMS   JSON 字串，覆寫下方 DEFAULT_PARAMS
  LAM_MODEL_DIR        權重資料夾
  LAM_INFER_CONFIG     推論設定 yaml

API：
  GET  /health                     不需金鑰；回報模型是否載入
  GET  /defaults                   目前預設參數、可用的 motion 名稱、參數範圍
  POST /jobs                       multipart：image=照片, params=JSON 字串（可只給要覆寫的欄位）
  GET  /jobs/{id}                  工作狀態
  GET  /jobs/{id}/manifest         完成後的影格清單（角度、在 bundle 中的位置）
  GET  /jobs/{id}/bundle           所有 JPEG 影格串接成的二進位檔
"""
import os
import sys
import io
import hmac
import json
import math
import time
import uuid
import glob
import shutil
import threading
import queue
import traceback
from collections import OrderedDict

LAM_ROOT = os.environ.get("LAM_ROOT", os.path.dirname(os.path.abspath(__file__)))
os.chdir(LAM_ROOT)
sys.path.insert(0, LAM_ROOT)
os.environ.setdefault("NUMBA_THREADING_LAYER", "omp")

import numpy as np
import cv2
import torch
from PIL import Image, ImageOps
from omegaconf import OmegaConf
from fastapi import FastAPI, UploadFile, File, Form, Header, HTTPException, Depends
from fastapi.responses import Response
import uvicorn

# --------------------------------------------------------------------------
# 設定
# --------------------------------------------------------------------------
API_KEY = os.environ.get("LAM_API_KEY", "")
PORT = int(os.environ.get("LAM_PORT", "8000"))
WORK_DIR = os.path.abspath(os.environ.get("LAM_WORK_DIR", "./lam_jobs"))
MAX_JOBS_KEPT = int(os.environ.get("LAM_MAX_JOBS", "20"))
MODEL_DIR = os.environ.get("LAM_MODEL_DIR", "./model_zoo/lam_models/releases/lam/lam-20k/step_045500/")
INFER_CONFIG = os.environ.get("LAM_INFER_CONFIG", "./configs/inference/lam-20k-8gpu.yaml")
MOTION_ROOT = "./assets/sample_motion/export"
MAX_UPLOAD_BYTES = 15 * 1024 * 1024

DEFAULT_PARAMS = {
    # 角度網格（度）
    "yaw_min": -30.0, "yaw_max": 30.0, "yaw_step": 2.5,
    "pitch_min": -10.0, "pitch_max": 10.0, "pitch_step": 5.0,
    # 輸出
    "out_size": 384,          # 輸出影格邊長（像素）
    "jpeg_quality": 85,
    "bg_color": "#FFFFFF",
    # 表情與姿態
    "expression": "neutral",  # neutral＝無表情；motion＝使用 motion 序列該影格的表情
    "motion_name": "",        # 取相機與基準姿態的 motion，空字串＝第一個
    "motion_frame": 0,
    "base_rotation": "camera",  # camera＝頭部正對相機；motion＝以該影格頭部姿態為基準；frontal＝零旋轉
    "yaw_sign": 1,            # 若左右方向相反，改成 -1
    "pitch_sign": 1,          # 正值＝抬頭；若上下方向相反，改成 -1
    # 效能
    "chunk_size": 64,         # 每批渲染的視角數，GPU 記憶體不足時調小
    "max_views": 400,         # 伺服器端上限（iPhone 不可覆寫）
}
if os.environ.get("LAM_DEFAULT_PARAMS"):
    DEFAULT_PARAMS.update(json.loads(os.environ["LAM_DEFAULT_PARAMS"]))

# 數值參數：(型別, 最小, 最大)
NUM_SPEC = {
    "yaw_min": (float, -60, 60), "yaw_max": (float, -60, 60), "yaw_step": (float, 0.5, 60),
    "pitch_min": (float, -30, 30), "pitch_max": (float, -30, 30), "pitch_step": (float, 0.5, 60),
    "out_size": (int, 128, 1024), "jpeg_quality": (int, 40, 100),
    "motion_frame": (int, 0, 100000),
    "yaw_sign": (int, -1, 1), "pitch_sign": (int, -1, 1),
    "chunk_size": (int, 4, 256),
}
CHOICES = {"expression": ["neutral", "motion"], "base_rotation": ["camera", "motion", "frontal"]}
SERVER_ONLY = {"max_views"}


def parse_hex_color(s):
    s = str(s).strip().lstrip("#")
    if len(s) != 6:
        raise ValueError(f"bg_color 必須是 #RRGGBB：{s}")
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32) / 255.0


def angle_list(lo, hi, step):
    if hi - lo < 1e-6:
        return [round(lo, 4)]
    n = int(math.floor((hi - lo) / step + 1e-6))
    vals = [lo + i * step for i in range(n + 1)]
    if hi - vals[-1] > 1e-6:
        vals.append(hi)
    return [round(v, 4) for v in vals]


def list_motions():
    return sorted(os.path.basename(os.path.dirname(p))
                  for p in glob.glob(os.path.join(MOTION_ROOT, "*", "flame_param")))


def resolve_params(user):
    if not isinstance(user, dict):
        raise ValueError("params 必須是 JSON 物件")
    p = dict(DEFAULT_PARAMS)
    for k, v in user.items():
        if k in SERVER_ONLY:
            continue
        if k not in p:
            raise ValueError(f"未知參數：{k}")
        if k in NUM_SPEC:
            t, lo, hi = NUM_SPEC[k]
            try:
                v = t(v)
            except (TypeError, ValueError):
                raise ValueError(f"{k} 必須是數字")
            if not (lo <= v <= hi):
                raise ValueError(f"{k}={v} 超出範圍 [{lo}, {hi}]")
            if k.endswith("_sign") and v == 0:
                raise ValueError(f"{k} 只能是 1 或 -1")
        elif k in CHOICES:
            if v not in CHOICES[k]:
                raise ValueError(f"{k} 只能是 {CHOICES[k]}")
        elif k == "bg_color":
            parse_hex_color(v)
        else:
            v = str(v)
        p[k] = v
    if p["yaw_min"] > p["yaw_max"]:
        raise ValueError("yaw_min 不可大於 yaw_max")
    if p["pitch_min"] > p["pitch_max"]:
        raise ValueError("pitch_min 不可大於 pitch_max")
    if p["motion_name"] and p["motion_name"] not in list_motions():
        raise ValueError(f"找不到 motion：{p['motion_name']}，可用：{list_motions()}")
    yaws = angle_list(p["yaw_min"], p["yaw_max"], p["yaw_step"])
    pitches = angle_list(p["pitch_min"], p["pitch_max"], p["pitch_step"])
    n = len(yaws) * len(pitches)
    if n > p["max_views"]:
        raise ValueError(f"視角數 {n} 超過上限 {p['max_views']}，請加大步距或縮小範圍")
    return p, yaws, pitches


# --------------------------------------------------------------------------
# 模型
# --------------------------------------------------------------------------
STATE = {"model_loaded": False, "load_error": None, "gpu": None}
LAM = None
CFG = None
TRACKER = None


def load_models():
    global LAM, CFG, TRACKER
    from lam.models import ModelLAM
    from safetensors.torch import load_file
    from tools.flame_tracking_single_image import FlameTrackingSingleImage

    STATE["gpu"] = torch.cuda.get_device_name(0) if torch.cuda.is_available() else None
    c = OmegaConf.load(INFER_CONFIG)
    cfg = OmegaConf.create()
    cfg.source_size = c.dataset.source_image_res
    cfg.render_size = c.dataset.render_image.high
    cfg.merge_with(c)
    cfg.model_name = MODEL_DIR

    model = ModelLAM(**cfg.model)
    ckpt = load_file(os.path.join(MODEL_DIR, "model.safetensors"), device="cpu")
    state = model.state_dict()
    for k, v in ckpt.items():
        if k in state and state[k].shape == v.shape:
            state[k].copy_(v)
        else:
            print(f"[WARN] 權重略過：{k}")
    LAM = model.to("cuda").eval()
    CFG = cfg

    TRACKER = FlameTrackingSingleImage(
        output_dir=os.path.join(WORK_DIR, "_tracking"),
        alignment_model_path="./model_zoo/flame_tracking_models/68_keypoints_model.pkl",
        vgghead_model_path="./model_zoo/flame_tracking_models/vgghead/vgg_heads_l.trcd",
        human_matting_path="./model_zoo/flame_tracking_models/matting/stylematte_synth.pt",
        facebox_model_path="./model_zoo/flame_tracking_models/FaceBoxesV2.pth",
        detect_iris_landmarks=False,
    )
    STATE["model_loaded"] = True
    print("[LAM] 模型載入完成", flush=True)


# --------------------------------------------------------------------------
# 工作管理
# --------------------------------------------------------------------------
JOBS = OrderedDict()
JOBS_LOCK = threading.Lock()
JOB_QUEUE = queue.Queue()


def update_job(jid, **kw):
    with JOBS_LOCK:
        if jid in JOBS:
            JOBS[jid].update(kw)


def public_status(job):
    with JOBS_LOCK:
        pos = None
        if job["status"] == "queued":
            pos = sum(1 for j in JOBS.values()
                      if j["status"] == "queued" and j["created"] < job["created"])
        return {
            "job_id": job["id"], "status": job["status"], "stage": job["stage"],
            "progress": round(job["progress"], 3), "error": job["error"],
            "queue_position": pos, "views": job["views"],
            "elapsed": round((job.get("finished") or time.time()) - job["created"], 1),
        }


def cleanup_jobs():
    with JOBS_LOCK:
        done = [k for k, j in JOBS.items() if j["status"] in ("done", "error")]
        while len(JOBS) > MAX_JOBS_KEPT and done:
            k = done.pop(0)
            shutil.rmtree(JOBS[k]["dir"], ignore_errors=True)
            del JOBS[k]


def camera_facing_rotation(c2w):
    """讓 FLAME 頭部（臉朝 +z、頭頂朝 +y）正對相機、頭頂朝畫面上方的旋轉矩陣。
    c2w 是 OpenCV 慣例（第 2 欄＝相機往前、第 1 欄＝畫面往下）"""
    c2w = c2w.float()
    z = -c2w[:3, 2]
    z = z / z.norm()
    up = -c2w[:3, 1]
    y = up - (up @ z) * z
    y = y / y.norm()
    x = torch.linalg.cross(y, z)
    return torch.stack([x, y, z], dim=1)


def rotation_for_views(base, views, yaw_sign, pitch_sign, mode):
    """回傳每個視角的頭部旋轉（axis-angle）。
    camera 模式下，角度是相對於相機視線的真實角度：yaw＝繞畫面垂直軸轉頭，pitch 正值＝抬頭"""
    from pytorch3d.transforms import axis_angle_to_matrix, matrix_to_axis_angle
    out = []
    for yaw, pitch in views:
        y = math.radians(yaw * yaw_sign)
        x = -math.radians(pitch * pitch_sign)   # 繞 +x 轉正角是低頭，所以取負號讓正值＝抬頭
        ry = axis_angle_to_matrix(torch.tensor([[0.0, y, 0.0]]))[0]
        rx = axis_angle_to_matrix(torch.tensor([[x, 0.0, 0.0]]))[0]
        if mode == "camera":
            r = base @ ry @ rx          # 先在頭部座標點頭、轉頭，再整顆轉向相機
        else:
            r = ry @ rx @ base
        out.append(matrix_to_axis_angle(r[None])[0])
    return torch.stack(out)  # [N, 3]


def run_job(job):
    from lam.runners.infer.head_utils import prepare_motion_seqs, preprocess_image

    jid, jd, p = job["id"], job["dir"], job["params"]
    yaws, pitches = job["yaws"], job["pitches"]
    t0 = time.time()

    # 1. FLAME 追蹤
    update_job(jid, stage="臉部追蹤", progress=0.05)
    raw = os.path.join(jd, f"{jid}.png")
    if TRACKER.preprocess(raw) != 0:
        raise RuntimeError("偵測不到人臉，請換一張正面、清楚的照片")
    if TRACKER.optimize() != 0:
        raise RuntimeError("FLAME 擬合失敗")
    rc, out_dir = TRACKER.export()
    if rc != 0:
        raise RuntimeError("FLAME 匯出失敗")

    image, _, _, shape_param = preprocess_image(
        os.path.join(out_dir, "images/00000_00.png"),
        mask_path=os.path.join(out_dir, "fg_masks/00000_00.png"),
        intr=None, pad_ratio=0, bg_color=1., max_tgt_size=None, aspect_standard=1.0,
        enlarge_ratio=[1.0, 1.0], render_tgt_size=CFG.source_size, multiply=14,
        need_mask=True, get_shape_param=True)

    # 2. 相機與姿態
    update_job(jid, stage="準備視角", progress=0.2)
    motions = list_motions()
    if not motions:
        raise RuntimeError("找不到 sample motion，請確認 LAM-assets 已解壓")
    motion = p["motion_name"] or motions[0]
    seq = prepare_motion_seqs(
        os.path.join(MOTION_ROOT, motion, "flame_param"), None, save_root=jd, fps=30,
        bg_color=1., aspect_standard=1.0, enlarge_ratio=[1.0, 1.0],
        render_image_res=CFG.render_size, multiply=16, need_mask=False, vis_motion=False,
        shape_param=shape_param, test_sample=False, cross_id=False, src_driven=["src", "drv"])

    n_frames = seq["render_c2ws"].shape[1]
    fi = min(p["motion_frame"], n_frames - 1)
    views = [(y, pt) for pt in pitches for y in yaws]  # 列：pitch，欄：yaw
    n = len(views)

    fp = {}
    for k, v in seq["flame_params"].items():
        if k == "betas":
            continue
        sel = v[:, fi:fi + 1]
        fp[k] = sel.repeat(1, n, *([1] * (sel.dim() - 2))).clone()
    if p["expression"] == "neutral":
        for k in ("expr", "jaw_pose", "eyes_pose", "neck_pose", "teeth_bs"):
            if k in fp:
                fp[k].zero_()
    from pytorch3d.transforms import axis_angle_to_matrix
    mode = p["base_rotation"]
    if mode == "camera":
        base = camera_facing_rotation(seq["render_c2ws"][0, fi])
    elif mode == "frontal":
        base = torch.eye(3)
    else:
        base = axis_angle_to_matrix(fp["rotation"][0, 0].reshape(1, 3).float())[0]
    fp["rotation"] = rotation_for_views(base, views, p["yaw_sign"], p["pitch_sign"], mode)[None]
    fp["betas"] = shape_param.unsqueeze(0)

    bg = parse_hex_color(p["bg_color"])
    c2ws = seq["render_c2ws"][:, fi:fi + 1].repeat(1, n, 1, 1)
    intrs = seq["render_intrs"][:, fi:fi + 1].repeat(1, n, 1, 1)
    bgs = torch.tensor(bg).view(1, 1, 3).repeat(1, n, 1)

    # 3. 生成 + 分批渲染
    dev = "cuda"
    img_t = image.unsqueeze(0).to(dev, torch.float32)
    chunk = int(p["chunk_size"])
    bundle = bytearray()
    frames = []
    width = height = None
    for s in range(0, n, chunk):
        e = min(n, s + chunk)
        update_job(jid, stage=f"渲染視角 {s + 1}–{e} / {n}", progress=0.25 + 0.7 * s / n)
        fpc = {k: (v.clone() if k == "betas" else v[:, s:e].clone()).to(dev) for k, v in fp.items()}
        with torch.no_grad():
            res = LAM.infer_single_view(
                img_t, None, None,
                render_c2ws=c2ws[:, s:e].to(dev), render_intrs=intrs[:, s:e].to(dev),
                render_bg_colors=bgs[:, s:e].to(dev), flame_params=fpc)
        rgb = res["comp_rgb"].float().cpu().numpy()
        mask = res["comp_mask"].float().cpu().numpy()
        del res
        mask = np.where(mask < 0.5, 0.0, mask)
        rgb = rgb * mask + (1 - mask) * bg
        rgb = (np.clip(rgb, 0, 1) * 255).astype(np.uint8)
        for i in range(rgb.shape[0]):
            im = rgb[i]
            h, w = im.shape[:2]
            scale = p["out_size"] / max(h, w)
            if abs(scale - 1) > 1e-3:
                im = cv2.resize(im, (round(w * scale), round(h * scale)),
                                interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_CUBIC)
            height, width = im.shape[:2]
            buf = io.BytesIO()
            Image.fromarray(im).save(buf, "JPEG", quality=int(p["jpeg_quality"]))
            data = buf.getvalue()
            yaw, pitch = views[s + i]
            frames.append({"yaw": yaw, "pitch": pitch, "offset": len(bundle), "length": len(data)})
            bundle.extend(data)

    # 4. 寫出
    update_job(jid, stage="打包", progress=0.97)
    with open(os.path.join(jd, "bundle.bin"), "wb") as f:
        f.write(bundle)
    manifest = {
        "job_id": jid, "yaws": yaws, "pitches": pitches, "width": width, "height": height,
        "frames": frames, "motion": motion, "params": p,
        "bundle_bytes": len(bundle), "seconds": round(time.time() - t0, 2),
    }
    with open(os.path.join(jd, "manifest.json"), "w") as f:
        json.dump(manifest, f, ensure_ascii=False)


def worker():
    try:
        load_models()
    except Exception as e:
        STATE["load_error"] = f"{type(e).__name__}: {e}"
        traceback.print_exc()
        return
    while True:
        jid = JOB_QUEUE.get()
        with JOBS_LOCK:
            job = JOBS.get(jid)
        if job is None:
            continue
        update_job(jid, status="running", stage="開始", progress=0.0)
        try:
            run_job(job)
            update_job(jid, status="done", stage="完成", progress=1.0, finished=time.time())
            print(f"[LAM] job {jid} 完成，{job['views']} 個視角", flush=True)
        except Exception as e:
            traceback.print_exc()
            update_job(jid, status="error", stage="失敗", error=str(e), finished=time.time())
        finally:
            torch.cuda.empty_cache()


# --------------------------------------------------------------------------
# HTTP API
# --------------------------------------------------------------------------
app = FastAPI(title="LAM iPhone API")


def check_key(x_api_key: str | None = Header(default=None)):
    if API_KEY and not hmac.compare_digest(x_api_key or "", API_KEY):
        raise HTTPException(status_code=401, detail="API Key 錯誤")


def get_job(jid):
    with JOBS_LOCK:
        job = JOBS.get(jid)
    if job is None:
        raise HTTPException(404, "找不到這個工作（可能已被清除或伺服器重啟）")
    return job


@app.get("/health")
def health():
    return {"status": "ok", "model_loaded": STATE["model_loaded"],
            "load_error": STATE["load_error"], "gpu": STATE["gpu"],
            "queued": JOB_QUEUE.qsize()}


@app.get("/defaults", dependencies=[Depends(check_key)])
def defaults():
    return {"params": DEFAULT_PARAMS, "motions": list_motions(),
            "limits": {k: [lo, hi] for k, (_, lo, hi) in NUM_SPEC.items()},
            "choices": CHOICES}


@app.post("/jobs", dependencies=[Depends(check_key)])
async def create_job(image: UploadFile = File(...), params: str = Form("{}")):
    if STATE["load_error"]:
        raise HTTPException(503, f"模型載入失敗：{STATE['load_error']}")
    data = await image.read()
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, "照片太大（上限 15 MB）")
    try:
        p, yaws, pitches = resolve_params(json.loads(params or "{}"))
    except json.JSONDecodeError:
        raise HTTPException(422, "params 不是合法的 JSON")
    except ValueError as e:
        raise HTTPException(422, str(e))
    try:
        img = ImageOps.exif_transpose(Image.open(io.BytesIO(data))).convert("RGB")
    except Exception:
        raise HTTPException(400, "無法讀取照片")

    jid = uuid.uuid4().hex[:12]
    jd = os.path.join(WORK_DIR, jid)
    os.makedirs(jd, exist_ok=True)
    img.save(os.path.join(jd, f"{jid}.png"))
    job = {"id": jid, "dir": jd, "params": p, "yaws": yaws, "pitches": pitches,
           "views": len(yaws) * len(pitches), "status": "queued",
           "stage": "排隊中" if STATE["model_loaded"] else "等待模型載入",
           "progress": 0.0, "error": None, "created": time.time(), "finished": None}
    with JOBS_LOCK:
        JOBS[jid] = job
    cleanup_jobs()
    JOB_QUEUE.put(jid)
    return public_status(job)


@app.get("/jobs/{jid}", dependencies=[Depends(check_key)])
def job_status(jid: str):
    return public_status(get_job(jid))


def _result_file(jid, name):
    job = get_job(jid)
    if job["status"] != "done":
        raise HTTPException(409, f"工作尚未完成（{job['status']}）")
    path = os.path.join(job["dir"], name)
    with open(path, "rb") as f:
        return f.read()


@app.get("/jobs/{jid}/manifest", dependencies=[Depends(check_key)])
def job_manifest(jid: str):
    return Response(_result_file(jid, "manifest.json"), media_type="application/json")


@app.get("/jobs/{jid}/bundle", dependencies=[Depends(check_key)])
def job_bundle(jid: str):
    return Response(_result_file(jid, "bundle.bin"), media_type="application/octet-stream")


def run_once(image_path, params_path, out_dir):
    """單次執行（給 Kaggle 自動送件用）：生成一次就結束，結果寫到 out_dir/manifest.json、bundle.bin"""
    os.makedirs(out_dir, exist_ok=True)
    try:
        os.makedirs(WORK_DIR, exist_ok=True)
        with open(params_path, encoding="utf-8") as f:
            user = json.load(f)
        p, yaws, pitches = resolve_params(user)
        img = ImageOps.exif_transpose(Image.open(image_path)).convert("RGB")
        load_models()
        jid = uuid.uuid4().hex[:12]
        jd = os.path.join(WORK_DIR, jid)
        os.makedirs(jd, exist_ok=True)
        img.save(os.path.join(jd, f"{jid}.png"))
        job = {"id": jid, "dir": jd, "params": p, "yaws": yaws, "pitches": pitches,
               "views": len(yaws) * len(pitches), "status": "running", "stage": "", "progress": 0.0,
               "error": None, "created": time.time(), "finished": None}
        JOBS[jid] = job
        run_job(job)
        for name in ("manifest.json", "bundle.bin"):
            shutil.copy(os.path.join(jd, name), os.path.join(out_dir, name))
        print(f"[LAM] 完成，{job['views']} 個視角", flush=True)
        return 0
    except Exception as e:
        traceback.print_exc()
        with open(os.path.join(out_dir, "error.txt"), "w", encoding="utf-8") as f:
            f.write(str(e) or type(e).__name__)
        return 1


if __name__ == "__main__" and len(sys.argv) == 5 and sys.argv[1] == "--once":
    _args = sys.argv[2:]
    sys.argv = sys.argv[:1]   # LAM 內部有 argparse 會讀 sys.argv，先清掉，不然會出現 unrecognized arguments
    sys.exit(run_once(*_args))

if __name__ == "__main__":
    os.makedirs(WORK_DIR, exist_ok=True)
    if not API_KEY:
        print("[WARN] 未設定 LAM_API_KEY，任何拿到網址的人都能使用", flush=True)
    threading.Thread(target=worker, daemon=True).start()
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="warning")
