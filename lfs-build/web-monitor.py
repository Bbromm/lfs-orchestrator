#!/usr/bin/env python3
###############################################################################
# web-monitor.py — Веб-панель мониторинга сборки LFS
#
# Запуск (на хосте, вне chroot):
#   python3 web-monitor.py --port 8080 --log-dir /root/lfs-build/logs
#
# Откройте в браузере: http://<host-ip>:8080
###############################################################################
import argparse
import json
import os
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HTML_PAGE = """<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<title>LFS Build Monitor</title>
<style>
  body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #1e1e2e; color: #cdd6f4; margin: 0; padding: 20px; }
  h1 { color: #89b4fa; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 15px; margin-top: 20px; }
  .phase { background: #313244; border-radius: 8px; padding: 15px; border-left: 5px solid #6c7086; }
  .phase.done { border-left-color: #a6e3a1; }
  .phase.running { border-left-color: #f9e2af; animation: pulse 1.5s infinite; }
  .phase.failed { border-left-color: #f38ba8; }
  @keyframes pulse { 50% { opacity: 0.6; } }
  .phase h3 { margin: 0 0 10px 0; color: #cba6f7; }
  .phase .status { font-weight: bold; }
  .phase .time { font-size: 0.85em; color: #9399b2; margin-top: 5px; }
  .log-tail { background: #181825; border-radius: 8px; padding: 15px; margin-top: 20px; max-height: 400px; overflow-y: auto; font-family: monospace; font-size: 0.85em; white-space: pre-wrap; }
  .stat { display: inline-block; margin-right: 20px; }
  .stat b { color: #89b4fa; font-size: 1.4em; }
  .progress-bar { background: #45475a; height: 20px; border-radius: 10px; overflow: hidden; margin: 10px 0; }
  .progress-fill { background: linear-gradient(90deg, #89b4fa, #a6e3a1); height: 100%; transition: width 0.5s; }
</style>
</head>
<body>
  <h1>🐧 LFS 13.1-systemd — Мониторинг сборки</h1>
  <div>
    <span class="stat">Фаз завершено: <b id="done-count">0</b></span>
    <span class="stat">Прогресс: <b id="progress-pct">0%</b></span>
    <span class="stat">Обновлено: <b id="last-update">-</b></span>
  </div>
  <div class="progress-bar"><div class="progress-fill" id="progress-bar" style="width:0%"></div></div>
  <div class="grid" id="phases"></div>
  <h2>Последние строки лога</h2>
  <div class="log-tail" id="log-tail">Загрузка...</div>

<script>
const PHASES = ['phase0','phase1','phase2','phase3','phase4','phase5','phase6','phase7','phase8'];
const NAMES = {
  phase0: 'Гл. 2-3: Подготовка хоста',
  phase1: 'Гл. 4: Финальные приготовления',
  phase2: 'Гл. 5: Кросс-инструментарий',
  phase3: 'Гл. 6: Временные инструменты',
  phase4: 'Гл. 7: Chroot + доп. инструменты',
  phase5: 'Гл. 8: Базовое ПО',
  phase6: 'Гл. 9: Конфигурация системы',
  phase7: 'Гл. 10: Ядро + GRUB',
  phase8: 'Гл. 11: Финализация'
};

const evtSource = new EventSource('/events');

evtSource.onmessage = (e) => {
  const data = JSON.parse(e.data);
  updateUI(data);
};

function updateUI(data) {
  const phasesEl = document.getElementById('phases');
  phasesEl.innerHTML = '';

  let done = 0;
  PHASES.forEach(p => {
    const state = data.phases[p] || { status: 'pending' };
    if (state.status === 'done') done++;

    const div = document.createElement('div');
    div.className = 'phase ' + state.status;
    let statusText = {
      'pending': '⏳ Ожидание',
      'running': '⚙ Выполняется',
      'done': '✔ Завершено',
      'failed': '✘ Ошибка'
    }[state.status] || state.status;

    div.innerHTML = `
      <h3>${NAMES[p]}</h3>
      <div class="status">${statusText}</div>
      ${state.duration ? `<div class="time">Длительность: ${state.duration}</div>` : ''}
      ${state.log ? `<div class="time">Лог: ${state.log}</div>` : ''}
    `;
    phasesEl.appendChild(div);
  });

  document.getElementById('done-count').textContent = done + ' / ' + PHASES.length;
  const pct = Math.round(done / PHASES.length * 100);
  document.getElementById('progress-pct').textContent = pct + '%';
  document.getElementById('progress-bar').style.width = pct + '%';
  document.getElementById('last-update').textContent = new Date().toLocaleTimeString('ru-RU');

  if (data.log_tail) {
    document.getElementById('log-tail').textContent = data.log_tail;
  }
}
</script>
</body>
</html>
"""


class StateReader:
    def __init__(self, state_dir, log_dir):
        self.state_dir = Path(state_dir)
        self.log_dir = Path(log_dir)

    def get_state(self):
        phases = {}
        for p in ['phase0','phase1','phase2','phase3','phase4','phase5','phase6','phase7','phase8']:
            done_file = self.state_dir / f"{p}.done"
            logs = sorted(self.log_dir.glob(f"{p}-*.log"))
            if done_file.exists():
                mtime = datetime.fromtimestamp(done_file.stat().st_mtime)
                phases[p] = {
                    'status': 'done',
                    'duration': self._duration(logs[-1]) if logs else '-',
                    'log': logs[-1].name if logs else None
                }
            elif logs:
                # Есть лог, но нет .done → либо running, либо failed
                log_file = logs[-1]
                content = self._tail(log_file, 20)
                if 'ERROR' in content or 'error:' in content.lower():
                    phases[p] = {'status': 'failed', 'log': log_file.name}
                else:
                    phases[p] = {'status': 'running', 'log': log_file.name}
            else:
                phases[p] = {'status': 'pending'}

        # Собираем последний лог
        all_logs = sorted(self.log_dir.glob('*.log'), key=lambda f: f.stat().st_mtime)
        log_tail = self._tail(all_logs[-1], 30) if all_logs else 'Логи не найдены'

        return {'phases': phases, 'log_tail': log_tail}

    def _tail(self, path, n=20):
        try:
            with open(path, 'r', errors='replace') as f:
                lines = f.readlines()
            return ''.join(lines[-n:])
        except Exception as e:
            return f'<не удалось прочитать {path}: {e}>'

    def _duration(self, log_file):
        try:
            mtime = datetime.fromtimestamp(log_file.stat().st_mtime)
            ctime = datetime.fromtimestamp(log_file.stat().st_ctime)
            delta = mtime - ctime
            return str(delta).split('.')[0]
        except Exception:
            return '-'


class Handler(BaseHTTPRequestHandler):
    state_reader = None

    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode('utf-8'))
        elif self.path == '/state':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(self.state_reader.get_state()).encode())
        elif self.path == '/events':
            self._sse()
        else:
            self.send_response(404)
            self.end_headers()

    def _sse(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'keep-alive')
        self.end_headers()
        try:
            while True:
                data = self.state_reader.get_state()
                self.wfile.write(f"data: {json.dumps(data)}\n\n".encode())
                self.wfile.flush()
                time.sleep(2)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, fmt, *args):
        pass  # Тихий режим


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=8080)
    ap.add_argument('--host', default='0.0.0.0')
    ap.add_argument('--state-dir', default='/root/lfs-build/state')
    ap.add_argument('--log-dir',   default='/root/lfs-build/logs')
    args = ap.parse_args()

    Handler.state_reader = StateReader(args.state_dir, args.log_dir)
    server = ThreadingHTTPServer((args.host, args.port), Handler)

    print(f"🌐 Мониторинг: http://{args.host}:{args.port}")
    print(f"   Состояние: {args.state_dir}")
    print(f"   Логи:      {args.log_dir}")
    print("   Ctrl+C для остановки")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nОстановлено")


if __name__ == '__main__':
    main()