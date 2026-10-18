# -*- coding: utf-8 -*-
"""
LAM 單次生成（每次在 iPhone 按「生成」時由 App 送到 Kaggle 執行，跑完自動結束）

輸入：
  - 資料集 lam-head-input：input_<JOB_ID>.jpg（App 上傳的照片）
  - 筆記本輸出 lam-env-build：lam_env.tar.zst（lam_env_build.py 建好的環境）
輸出（/kaggle/working）：result_meta.json、manifest.json、bundle.bin

App 送出前會替換：__JOB_ID__、__PARAMS_B64__、__ENV_VERSION__、__LAM_SERVER_B64__
"""
import os, sys, json, time, glob, base64, shutil, subprocess, traceback

JOB_ID = "__JOB_ID__"
PARAMS_B64 = "__PARAMS_B64__"
ENV_VERSION = "__ENV_VERSION__"
LAM_SERVER_B64 = "__LAM_SERVER_B64__"

WORK = "/tmp/lam"
OUT = "/kaggle/working"
T0 = time.time()


def log(*a):
    print(time.strftime("%H:%M:%S"), f"[{int(time.time() - T0):4d} 秒]", *a, flush=True)


def write_meta(status, error=None, message=None, **kw):
    m = {"jobId": JOB_ID, "status": status, "error": error, "message": message,
         "elapsed_s": round(time.time() - T0, 1)}
    m.update(kw)
    with open(f"{OUT}/result_meta.json", "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False)


class JobFail(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def find(pattern):
    hits = sorted(glob.glob(f"/kaggle/input/**/{pattern}", recursive=True))
    return hits[0] if hits else None


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in glob.glob(f"{OUT}/*"):
        shutil.rmtree(f, ignore_errors=True) if os.path.isdir(f) else os.remove(f)
    write_meta("running")

    photo = find(f"input_{JOB_ID}.jpg")
    if not photo:
        raise JobFail("stale_input", "Kaggle 資料集還沒更新到這次的照片")

    env_meta_path = find("env_meta.json")
    env_meta = json.load(open(env_meta_path)) if env_meta_path else {}
    archive = find("lam_env.tar.zst") or find("lam_env.tar.gz")
    if not archive or env_meta.get("status") != "ok":
        raise JobFail("no_env", "還沒有建立 Kaggle 環境，請到 App 設定頁按「建立 Kaggle 環境」")
    if env_meta.get("env_version") != ENV_VERSION:
        raise JobFail("env_outdated", "Kaggle 環境版本過舊，請到 App 設定頁重新「建立 Kaggle 環境」")

    log("解壓環境", archive, f"{os.path.getsize(archive) / 1e9:.1f} GB")
    shutil.rmtree(WORK, ignore_errors=True)
    unpack = "zstd -dc" if archive.endswith(".zst") else "gzip -dc"
    subprocess.run(["bash", "-c", f"set -eo pipefail; {unpack} '{archive}' | tar -xf - -C /"], check=True)
    t_unpack = time.time() - T0

    with open(f"{WORK}/LAM/lam_server.py", "wb") as f:
        f.write(base64.b64decode(LAM_SERVER_B64))
    with open("/tmp/params.json", "wb") as f:
        f.write(base64.b64decode(PARAMS_B64))

    env = dict(os.environ, LAM_ROOT=f"{WORK}/LAM", LAM_WORK_DIR=f"{WORK}/jobs",
               TORCH_EXTENSIONS_DIR=f"{WORK}/torch_ext", TORCH_CUDA_ARCH_LIST="7.5",
               PATH=f"{WORK}/venv/bin:" + os.environ["PATH"])
    env.pop("PYTHONPATH", None)
    log("開始生成")
    r = subprocess.run([f"{WORK}/venv/bin/python", "lam_server.py", "--once", photo, "/tmp/params.json", "/tmp/out"],
                       cwd=f"{WORK}/LAM", env=env)
    err_file = "/tmp/out/error.txt"
    if r.returncode != 0 or not os.path.exists("/tmp/out/bundle.bin"):
        msg = open(err_file, encoding="utf-8").read() if os.path.exists(err_file) else f"程式結束碼 {r.returncode}"
        raise JobFail("generate", msg)

    for name in ("manifest.json", "bundle.bin"):
        shutil.move(f"/tmp/out/{name}", f"{OUT}/{name}")
    write_meta("ok", unpack_s=round(t_unpack, 1),
               bundle_mb=round(os.path.getsize(f"{OUT}/bundle.bin") / 1e6, 2))
    log("✅ 完成")


if __name__ == "__main__":
    try:
        main()
    except JobFail as e:
        log("❌", e)
        write_meta("error", e.code, str(e))
    except Exception as e:
        traceback.print_exc()
        write_meta("error", "exception", f"{type(e).__name__}: {e}"[-800:])
