#!/usr/bin/env bash
# 验证测试供应商可达性，并探测 embedding 输出维度。
#
# 用法：
#   1) 把 key 写进 ~/.pinland/providers.env（该目录不在仓库内；沿用旧名，不随改名迁移）：
#        MINIMAX_API_KEY=...
#        DASHSCOPE_API_KEY=...
#   2) bash scripts/verify-providers.sh
#
# key 只从环境变量读取，不接受命令行参数，不回显，不写入任何文件。
set -uo pipefail

# 老环境变量和旧目录都继续认：用户机器上的 key 已经放在那儿了，
# 改名不该让人把密钥文件挪一遍。
ENV_FILE="${MNEMO_ENV_FILE:-${MNEMO_ENV_FILE:-$HOME/.pinland/providers.env}}"
if [[ -f "$ENV_FILE" ]]; then
  set -a; . "$ENV_FILE"; set +a
  echo "已加载 $ENV_FILE"
else
  echo "未找到 $ENV_FILE，改用当前环境变量"
fi

MINIMAX_BASE="${MINIMAX_BASE:-https://api.minimaxi.com/anthropic/v1}"
MINIMAX_MODEL="${MINIMAX_MODEL:-MiniMax-M2.5}"
DASHSCOPE_BASE="${DASHSCOPE_BASE:-https://dashscope.aliyuncs.com/compatible-mode/v1}"
EMBED_MODEL="${EMBED_MODEL:-qwen3.7-text-embedding}"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }

# ---------- 1. MiniMax · Anthropic Messages 方言 ----------
echo
echo "[1/3] MiniMax 对话 · Anthropic Messages 方言"
echo "      $MINIMAX_BASE  model=$MINIMAX_MODEL"
if [[ -z "${MINIMAX_API_KEY:-}" ]]; then
  no "MINIMAX_API_KEY 未设置，跳过"
else
  body='{"model":"'"$MINIMAX_MODEL"'","max_tokens":16,"messages":[{"role":"user","content":"回复 OK 两个字"}]}'
  # 两种鉴权头都试，报告哪种可用
  for scheme in "x-api-key: $MINIMAX_API_KEY" "Authorization: Bearer $MINIMAX_API_KEY"; do
    label="${scheme%%:*}"
    code=$(curl -sS -o /tmp/mm.json -w '%{http_code}' --max-time 30 \
      -X POST "$MINIMAX_BASE/messages" \
      -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
      -H "$scheme" -d "$body" 2>/dev/null)
    if [[ "$code" == "200" ]]; then
      ok "鉴权头 $label 可用，HTTP 200"
      python3 - <<'PY' 2>/dev/null || true
import json
d = json.load(open("/tmp/mm.json"))
txt = "".join(b.get("text","") for b in d.get("content",[]) if isinstance(b,dict))
print(f"     返回: {txt[:60]!r}")
u = d.get("usage",{})
print(f"     用量: 输入 {u.get('input_tokens')} / 输出 {u.get('output_tokens')} token")
PY
      break
    else
      echo "     鉴权头 $label → HTTP $code"
    fi
  done
  [[ "$code" == "200" ]] || no "两种鉴权头均失败，最后一次 HTTP $code；响应见 /tmp/mm.json"
fi

# ---------- 2. 百炼 · OpenAI 兼容方言（对话） ----------
echo
echo "[2/3] 阿里云百炼对话 · OpenAI 兼容方言"
echo "      $DASHSCOPE_BASE"
if [[ -z "${DASHSCOPE_API_KEY:-}" ]]; then
  no "DASHSCOPE_API_KEY 未设置，跳过"
else
  code=$(curl -sS -o /tmp/ds.json -w '%{http_code}' --max-time 30 \
    -X POST "$DASHSCOPE_BASE/chat/completions" \
    -H "content-type: application/json" -H "Authorization: Bearer $DASHSCOPE_API_KEY" \
    -d '{"model":"qwen3.7-flash","max_tokens":16,"messages":[{"role":"user","content":"回复 OK 两个字"}]}' 2>/dev/null)
  [[ "$code" == "200" ]] && ok "HTTP 200，OpenAI 兼容方言可用" \
                         || no "HTTP $code；响应见 /tmp/ds.json"
fi

# ---------- 3. embedding 维度探测 ----------
echo
echo "[3/3] embedding 维度探测 · model=$EMBED_MODEL"
if [[ -z "${DASHSCOPE_API_KEY:-}" ]]; then
  no "DASHSCOPE_API_KEY 未设置，跳过"
else
  code=$(curl -sS -o /tmp/emb.json -w '%{http_code}' --max-time 30 \
    -X POST "$DASHSCOPE_BASE/embeddings" \
    -H "content-type: application/json" -H "Authorization: Bearer $DASHSCOPE_API_KEY" \
    -d '{"model":"'"$EMBED_MODEL"'","input":"维度探测"}' 2>/dev/null)
  if [[ "$code" == "200" ]]; then
    python3 - <<'PY'
import json
d = json.load(open("/tmp/emb.json"))
v = d["data"][0]["embedding"]
print(f"  ✅ HTTP 200，输出维度 = {len(v)}")
print(f"     单条向量体积 ≈ {len(v)*4/1024:.1f} KB（float32）")
print(f"     1000 条约 {len(v)*4*1000/1024/1024:.1f} MB —— 填进 test-strategy 的实测维度")
PY
    pass=$((pass+1))
  else
    no "HTTP $code；模型名可能不存在，响应见 /tmp/emb.json"
  fi
fi

echo
echo "───────────── 通过 $pass · 失败 $fail ─────────────"
rm -f /tmp/mm.json /tmp/ds.json /tmp/emb.json
[[ $fail -eq 0 ]]
