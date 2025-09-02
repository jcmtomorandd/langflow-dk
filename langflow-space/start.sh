python3 - <<'PY'
import json, os, glob, pathlib, sys
KB="/data/kb"; OUT="/data/flows/_patched"; os.makedirs(OUT, exist_ok=True)
ALLOWED={".pdf",".txt",".md",".csv",".docx",".json",".yaml",".yml",".xlsx"}

# /data/kb を再帰走査して {basename:[フルパス,..]} を作成（同名が複数でも保持）
kb_index={}
for root, _, files in os.walk(KB):
    for fn in files:
        full=os.path.join(root, fn)
        kb_index.setdefault(fn.lower(), []).append(full)

def resolve_to_kb_path(p:str)->str:
    """与えられたパス/ファイル名を /data/kb 配下の実在フルパスへ解決。相対/絶対/ファイル名だけにも対応。"""
    p = str(p).replace("\\","/")
    # すでに /data/kb から始まるならそのまま
    if p.startswith(KB + "/") or p==KB:
        return p
    # リポジトリ側のパス（langflow-space/kb/... 等）が残っていたら、末尾名で解決
    base = os.path.basename(p)
    if base.lower() in kb_index:
        # 同名が複数あっても先頭を選択（決め打ち）。必要なら後で明示指定可。
        return kb_index[base.lower()][0]
    # 最後の手段：/data/kb 直下に置いたとみなす
    return os.path.join(KB, base)

def rewrite_paths(v):
    if isinstance(v, str):
        return resolve_to_kb_path(v)
    if isinstance(v, list):
        return [rewrite_paths(i) for i in v]
    return v

def make_files_list(paths):
    """UIの File カードに出す 'files': [{'name','path'},…] を作成（存在確認＆拡張子チェックあり）。"""
    items=[]
    cand = [paths] if isinstance(paths, str) else (paths if isinstance(paths, list) else [])
    for c in cand:
        p = resolve_to_kb_path(c)
        ext = os.path.splitext(p)[1].lower()
        if os.path.exists(p) and (not ALLOWED or ext in ALLOWED):
            items.append({"name": os.path.basename(p), "path": p})
    return items

def walk(x):
    if isinstance(x, dict):
        y = {k: walk(v) for k,v in x.items()}
        # 1) APIキー系は除去（環境変数→Global Variable で供給）
        for key in list(y.keys()):
            if key.lower() in {"api_key","cohere_api_key","openai_api_key","huggingfacehub_api_token"}:
                y.pop(key, None)
        # 2) パス系キーを実在パスへ解決（サブフォルダ維持）
        src_val=None
        for key in list(y.keys()):
            if key.lower() in {"file_paths","paths","file_path","path"}:
                y[key] = rewrite_paths(y[key])
                src_val = y[key]
        # 3) UI用 'files' が未設定/空なら補完（name+path）
        fk = next((k for k in y.keys() if k.lower()=="files"), None)
        if fk is None:
            files = make_files_list(src_val)
            if files: y["files"] = files
        elif not y.get(fk):
            files = make_files_list(src_val)
            if files: y[fk] = files
        return y
    if isinstance(x, list):
        return [walk(i) for i in x]
    return x

found=False
# flows/ はリポジトリ直下 or langflow-space/ 配下の両方に対応
cands=[os.path.join(os.path.dirname(__file__),"flows"),
       os.path.join(os.path.dirname(os.path.dirname(__file__)),"flows")]
for base in cands:
    for src in glob.glob(os.path.join(base, "*.json")):
        found=True
        with open(src, "r", encoding="utf-8") as f:
            data = json.load(f)
        data = walk(data)
        dst = os.path.join(OUT, pathlib.Path(src).name)
        with open(dst, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

print("Patched flows ready (subfolders kept)." if found else "No flow JSON found.")
PY
