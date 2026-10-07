# -*- coding: utf-8 -*-
"""
LAM 執行環境建置（只需要執行一次）

由 iPhone App 的「建立 Kaggle 環境」送到 Kaggle 執行（GPU T4、需開網路）。
會安裝套件、編譯 CUDA 程式、下載模型權重、用範例照片試跑一次，
最後把整個環境打包成 /kaggle/working/lam_env.tar.zst。
之後每次生成時，lam_job.py 會把這個輸出當作輸入直接解壓使用，不必重新安裝。

App 送出前會替換：__BUILD_ID__、__ENV_VERSION__、__LAM_SERVER_B64__
"""
import os, sys, json, time, glob, base64, shutil, subprocess, traceback

BUILD_ID = "__BUILD_ID__"
ENV_VERSION = "__ENV_VERSION__"
LAM_SERVER_B64 = "__LAM_SERVER_B64__"

WORK = "/tmp/lam"                 # 解壓後也必須是同一個路徑（venv 內有絕對路徑）
OUT = "/kaggle/working"
T0 = time.time()

ENV = dict(os.environ,
           WORK=WORK,
           UV_PYTHON_INSTALL_DIR=f"{WORK}/py",        # Python 本體也放進 WORK，一起打包
           UV_CACHE_DIR="/tmp/uv-cache", PIP_CACHE_DIR="/tmp/pip-cache",
           TORCH_EXTENSIONS_DIR=f"{WORK}/torch_ext",  # nvdiffrast 即時編譯的結果也一起打包
           TORCH_CUDA_ARCH_LIST="7.5", FORCE_CUDA="1", MAX_JOBS="4",
           PATH=f"{WORK}/venv/bin:" + os.environ["PATH"])
ENV.pop("PYTHONPATH", None)


def log(*a):
    print(time.strftime("%H:%M:%S"), f"[{int(time.time() - T0) // 60:3d} 分]", *a, flush=True)


def write_meta(**kw):
    m = {"kind": "env", "build_id": BUILD_ID, "env_version": ENV_VERSION, "elapsed_s": round(time.time() - T0)}
    m.update(kw)
    with open(f"{OUT}/env_meta.json", "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False)


def sh(cmd, step):
    log("▶", step)
    r = subprocess.run(["bash", "-c", "set -eo pipefail\n" + cmd], env=ENV,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(r.stdout[-6000:], flush=True)
    if r.returncode != 0:
        raise RuntimeError(f"{step} 失敗：\n" + r.stdout[-1500:])


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in glob.glob(f"{OUT}/*"):
        shutil.rmtree(f, ignore_errors=True) if os.path.isdir(f) else os.remove(f)
    write_meta(status="running")
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)

    sh("nvidia-smi --query-gpu=name,memory.total --format=csv; nvcc --version | tail -n 1", "檢查 GPU")
    sh(f"{sys.executable} -m pip install -q uv && uv venv --python 3.10 --seed $WORK/venv && $WORK/venv/bin/python --version",
       "建立 Python 3.10 環境")
    sh("cd $WORK && git clone -q --depth 1 https://github.com/aigc3d/LAM.git", "下載 LAM 程式")
    sh("""cd $WORK/LAM
pip install -q torch==2.3.0 torchvision==0.18.0 torchaudio==2.3.0 --index-url https://download.pytorch.org/whl/cu121
pip install -q -U xformers==0.0.26.post1 --index-url https://download.pytorch.org/whl/cu121
grep -vE '^(git\\+|nvdiffrast@|chumpy)' requirements.txt > /tmp/req.txt
pip install -q -r /tmp/req.txt
# chumpy 的 setup.py 需要 import pip，要關閉 build isolation；--no-deps 避免 numpy 被升到 2.x
pip install -q --no-build-isolation --no-deps chumpy
pip install -q fastapi "uvicorn[standard]" python-multipart "websockets>=10,<12"
""", "安裝 Python 套件")
    sh("""cd $WORK/LAM
pip install -q --no-build-isolation --no-deps \\
  "git+https://github.com/facebookresearch/pytorch3d.git@V0.7.8" \\
  "git+https://github.com/ashawkey/diff-gaussian-rasterization/" \\
  "nvdiffrast@git+https://github.com/ShenhanQian/nvdiffrast@backface-culling" \\
  "git+https://github.com/camenduru/simple-knn/"
cd external/landmark_detection/FaceBoxesV2/utils/ && sh make.sh > /dev/null
python -c "import torch, pytorch3d, diff_gaussian_rasterization, simple_knn; print('torch', torch.__version__, 'CUDA', torch.cuda.is_available())"
""", "編譯 CUDA 套件（約 20–40 分鐘）")
    sh("""cd $WORK/LAM
huggingface-cli download 3DAIGC/LAM-assets --local-dir ./tmp
tar -xf ./tmp/LAM_assets.tar && rm ./tmp/LAM_assets.tar
tar -xf ./tmp/thirdparty_models.tar && rm -r ./tmp/
huggingface-cli download 3DAIGC/LAM-20K --local-dir ./model_zoo/lam_models/releases/lam/lam-20k/step_045500/
rm -rf ~/.cache/huggingface model_zoo/lam_models/releases/lam/lam-20k/step_045500/.cache
ls assets/sample_motion/export
""", "下載模型權重")

    with open(f"{WORK}/LAM/lam_server.py", "wb") as f:
        f.write(base64.b64decode(LAM_SERVER_B64))
    sample = sorted(glob.glob(f"{WORK}/LAM/assets/sample_input/*.jpg"))[0]
    with open("/tmp/warmup_params.json", "w") as f:
        json.dump({"yaw_min": -30, "yaw_max": 30, "yaw_step": 30, "pitch_min": 0, "pitch_max": 0}, f)
    sh(f"""cd $WORK/LAM
LAM_ROOT=$WORK/LAM LAM_WORK_DIR=$WORK/jobs python lam_server.py --once {sample} /tmp/warmup_params.json /tmp/warmup
cat /tmp/warmup/manifest.json | head -c 300""", "用範例照片試跑（同時完成 nvdiffrast 編譯）")

    sh("""rm -rf $WORK/jobs $WORK/LAM/.git
find $WORK -name __pycache__ -prune -exec rm -rf {} + || true
du -sh $WORK
cd /
if command -v zstd >/dev/null; then
  tar -cf - tmp/lam | zstd -q -T0 -3 -o /kaggle/working/lam_env.tar.zst
else
  tar -cf - tmp/lam | gzip -1 > /kaggle/working/lam_env.tar.gz
fi
ls -lh /kaggle/working""", "打包環境")
    out = (glob.glob(f"{OUT}/lam_env.tar.*") or [None])[0]
    size_gb = os.path.getsize(out) / 1e9
    if size_gb > 19.5:
        raise RuntimeError(f"打包後 {size_gb:.1f} GB，超過 Kaggle 輸出上限 20 GB")
    write_meta(status="ok", archive=os.path.basename(out), size_gb=round(size_gb, 2))
    log(f"✅ 完成，環境 {size_gb:.1f} GB")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        traceback.print_exc()
        for f in glob.glob(f"{OUT}/lam_env.tar.*"):
            os.remove(f)
        write_meta(status="error", message=str(e)[-1500:])   # 正常結束，讓 App 讀得到錯誤原因
