// LFS Orchestrator Web UI
const API = "";
let currentBuild = null;
let ws = null;

const $ = (id) => document.getElementById(id);

async function api(path, opts = {}) {
    const r = await fetch(API + path, {
        headers: { "Content-Type": "application/json" },
        ...opts,
    });
    if (!r.ok) throw new Error(await r.text());
    return r.json();
}

async function startBuild() {
    const phases = prompt("Фазы через запятую:",
        "phase5,phase6,phase7,phase8,phase9,phase10,phase11");
    if (!phases) return;

    const resp = await api("/api/builds", {
        method: "POST",
        body: JSON.stringify({
            phases: phases.split(",").map(s => s.trim()),
            config_path: "config/lfs-default.yaml",
        }),
    });
    currentBuild = resp.build_id;
    $("build-id").textContent = currentBuild;
    switchButtons(true);
    connectWS();
    pollLoop();
}

async function stopBuild() {
    if (!currentBuild) return;
    await api(`/api/builds/${currentBuild}/stop`, { method: "POST" });
}

async function pauseBuild() {
    if (!currentBuild) return;
    await api(`/api/builds/${currentBuild}/pause`, { method: "POST" });
}

async function resumeBuild() {
    if (!currentBuild) return;
    await api(`/api/builds/${currentBuild}/resume`, { method: "POST" });
}

function switchButtons(running) {
    $("start-btn").disabled = running;
    $("stop-btn").disabled = !running;
    $("pause-btn").disabled = !running;
    $("resume-btn").disabled = !running;
}

function appendLog(entry) {
    const log = $("log");
    const line = document.createElement("div");
    line.className = entry.level || "info";
    line.textContent = `[${entry.ts.slice(11, 19)}] [${entry.level.toUpperCase()}] ${entry.message}`;
    log.appendChild(line);
    log.scrollTop = log.scrollHeight;
    while (log.children.length > 500) log.removeChild(log.firstChild);
}

function connectWS() {
    if (ws) ws.close();
    const proto = location.protocol === "https:" ? "wss" : "ws";
    ws = new WebSocket(`${proto}://${location.host}/ws/logs/${currentBuild}`);
    ws.onmessage = (e) => appendLog(JSON.parse(e.data));
    ws.onclose = () => setTimeout(connectWS, 3000);
}

async function refresh() {
    if (!currentBuild) return;
    try {
        const b = await api(`/api/builds/${currentBuild}`);
        renderBuild(b);
    } catch (e) {
        console.error(e);
    }
}

function renderBuild(b) {
    const phases = {};
    let total = 0, done = 0, failed = 0;

    for (const task of b.tasks) {
        total++;
        if (task.state === "done") done++;
        if (task.state === "failed") failed++;
        if (!phases[task.phase]) phases[task.phase] = [];
        phases[task.phase].push(task);
    }

    const pct = total ? Math.round((done / total) * 100) : 0;
    $("stat-total").textContent = total;
    $("stat-done").textContent = done;
    $("stat-failed").textContent = failed;
    $("stat-progress").textContent = pct + "%";
    $("progress-bar").style.width = pct + "%";

    const container = $("phases");
    container.innerHTML = "";

    for (const [phaseName, tasks] of Object.entries(phases)) {
        const div = document.createElement("div");
        const state = tasks.every(t => t.state === "done") ? "done"
                   : tasks.some(t => t.state === "failed") ? "failed"
                   : tasks.some(t => t.state === "running") ? "running" : "pending";
        div.className = "phase " + state;
        div.innerHTML = `<h3>${phaseName}</h3>
            <div class="tasks">
                ${tasks.map(t => `<span class="task ${t.state}">${t.name} ${t.duration ? `(${t.duration.toFixed(1)}s)` : ""}</span>`).join("")}
            </div>`;
        container.appendChild(div);
    }

    if (b.status === "done" || b.status === "failed") {
        switchButtons(false);
        if (ws) { ws.close(); ws = null; }
    }
}

function pollLoop() {
    refresh();
    const int = setInterval(() => {
        refresh();
        if (!currentBuild) clearInterval(int);
    }, 3000);
}

// Event handlers
$("start-btn").onclick = startBuild;
$("stop-btn").onclick = stopBuild;
$("pause-btn").onclick = pauseBuild;
$("resume-btn").onclick = resumeBuild;

// При загрузке — если есть последняя сборка в localStorage
const lastBuild = localStorage.getItem("last_build");
if (lastBuild) {
    currentBuild = lastBuild;
    $("build-id").textContent = lastBuild;
    refresh();
    connectWS();
    pollLoop();
}