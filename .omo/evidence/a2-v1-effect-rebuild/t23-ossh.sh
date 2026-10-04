#!/data/data/com.termux/files/usr/bin/bash
# oscar (10.254.129.10:8022) 远程执行助手 — task-23 专用
# 用法: ossh '<shell 脚本>'   （脚本在远端以 bash -s 执行）
export SSHPASS='0'
exec sshpass -e ssh -p 8022 \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o ConnectTimeout=20 \
  u0_a450@10.254.129.10 "bash -s"
