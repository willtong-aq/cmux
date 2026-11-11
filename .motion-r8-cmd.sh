cd webviews
rm -f ../.motion-r8-cmd.sh
VP=./node_modules/.bin/vp; [ -x "$VP" ] || VP="bunx vp"
$VP fmt >/dev/null 2>&1; echo "FMT_EXIT=$?"
echo "FMT_TAR_BEGIN"; git status --porcelain -- . | awk '{print $2}' | sed 's#^webviews/##' | grep -v '^\.\./' | tar cz -T - 2>/dev/null | base64 -w0; echo; echo "FMT_TAR_END"
bun run typecheck 2>&1 | tail -6; echo "TSC_EXIT=${PIPESTATUS[0]}"
$VP lint 2>&1 | tail -6; echo "LINT_EXIT=${PIPESTATUS[0]}"
bun test src/agent-session/acpmux/conversation/turnEndFold.test.ts src/agent-session/acpmux/conversation/followChase.test.ts src/agent-session/acpmux/subagents/trayHeadOrder.test.ts src/agent-session/acpmux/conversation/Thinking.test.tsx test/status-swap-frames.test.ts test/agent-pane-composer-dock-motion.test.ts test/agent-pane-turn-end-motion.test.ts test/agent-pane-stream-row-overlap.test.ts test/turn-transition-jumps.test.ts test/send-stream-motion.test.ts test/row-arrival-settle.test.ts test/gallery-agent-pane-entries.test.ts test/agent-pane-fold-keeps-place.test.ts 2>&1 | grep -E "REPORT|\(pass\)|\(fail\)| pass$| fail$|beginFrame' wasn't" | head -400
mkdir -p /tmp/caps && bun scripts/gallery/capture-states.mjs ../.motion-capture-spec.json /tmp/caps 2>&1 | tail -3
echo "CAPS_BEGIN"; (cd /tmp/caps && tar cz $(find . -name 'now-*.png') ) | base64 -w0; echo; echo "CAPS_END"
