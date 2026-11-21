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

async function startBuild(force) {
    let phases;
    try {
        const info = await api("/api/phases");
        const list = info.phases.map(p => `${p.name} (${p.tasks})`).join("\n");
        phases = prompt(
            "Фазы через запятую.\nДоступны:\n" + list,
            info.default_phases.join(",")
        );
    } catch (e) {
        phases = prompt("Фазы через запятую:", "phase5,phase6");
    }
    if (!phases) return;

    const resp = await api("/api/builds", {
        method: "POST",
        body: JSON.stringify({
            phases: phases.split(",").map(s => s.trim()).filter(Boolean),
            config_path: "config/lfs-default.yaml",
            force: !!force,
        }),
    });
    currentBuild = resp.build_id;
    localStorage.setItem("last_build", currentBuild);
    $("build-id").textContent = currentBuild;
    $("log").innerHTML = "";
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
    $("rebuild-btn").disabled = running;   // ← ДОБАВИТЬ
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
    let total = 0, done = 0, failed = 0, skipped = 0;

    for (const task of b.tasks) {
        total++;
        if (task.state === "done") done++;
        if (task.state === "skipped") skipped++;
        if (task.state === "failed") failed++;
        if (!phases[task.phase]) phases[task.phase] = [];
        phases[task.phase].push(task);
    }

    // пропущенные по маркерам считаем выполненными — иначе прогресс стоит на нуле
    const finished = done + skipped;
    const pct = total ? Math.round((finished / total) * 100) : 0;
    $("stat-total").textContent = total;
    $("stat-done").textContent = done;
    const elSkipped = $("stat-skipped");
    if (elSkipped) elSkipped.textContent = skipped;
    $("stat-failed").textContent = failed;
    $("stat-progress").textContent = pct + "%";
    $("progress-bar").style.width = pct + "%";

    const container = $("phases");
    container.innerHTML = "";

    for (const [phaseName, tasks] of Object.entries(phases)) {
        const div = document.createElement("div");
        const state = tasks.every(t => t.state === "done" || t.state === "skipped") ? "done"
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
$("start-btn").onclick   = () => startBuild(false);
$("rebuild-btn").onclick = () => {
    if (confirm("Пересобрать все пакеты с нуля?")) startBuild(true);
};
$("stop-btn").onclick    = stopBuild;
$("pause-btn").onclick   = pauseBuild;
$("resume-btn").onclick  = resumeBuild;

// При загрузке — если есть последняя сборка в localStorage
async function attachToLatest() {
    try {
        const builds = await api("/api/builds");
        if (!Array.isArray(builds) || builds.length === 0) return;
        // API отдаёт сборки новыми вперёд, поэтому свежая — первая
        const last = builds[0];
        if (!last || !last.id) return;
        currentBuild = last.id;
        localStorage.setItem("last_build", currentBuild);
        $("build-id").textContent = currentBuild;
        switchButtons(last.status === "running");
        refresh();
        connectWS();
        pollLoop();
    } catch (e) {
        console.error("attachToLatest:", e);
    }
}

// ---- Настройки ----

function toggleStaticOnly() {
    const mode = $("set-net-mode").value;
    for (const el of document.querySelectorAll(".static-only")) {
        el.classList.toggle("hidden", mode !== "static");
    }
}

function toggleEspOnly() {
    const mode = $("set-boot-mode").value;
    for (const el of document.querySelectorAll(".esp-only")) {
        el.classList.toggle("hidden", mode === "bios");
    }
}

function fillSettings(s) {
    $("set-net-mode").value = s.network.mode || "dhcp";
    $("set-iface").value = s.network.iface || "";
    $("set-ip").value = s.network.ip || "";
    $("set-prefix").value = s.network.prefix || 24;
    $("set-gateway").value = s.network.gateway || "";
    $("set-dns1").value = s.network.dns1 || "";
    $("set-dns2").value = s.network.dns2 || "";
    $("set-hostname").value = s.system.hostname || "";
    $("set-timezone").value = s.system.timezone || "";
    $("set-locale").value = s.system.locale || "";
    $("set-keymap").value = s.system.keymap || "";
    $("set-user").value = s.user.name || "";
    $("set-password").value = "";
    $("set-password").placeholder = s.user.password_set
        ? "пароль задан — оставьте пустым, чтобы не менять"
        : "пароль не задан";
    $("set-groups").value = s.user.groups || "";
    $("set-nix").checked = !!s.extras.nix;
    $("set-ssh").checked = !!s.extras.ssh;
    $("set-sudo").checked = !!s.extras.sudo;
    $("set-pam").checked = !!s.extras.pam;
    $("set-xfce").checked = !!s.extras.xfce;

    const boot = s.boot || {};
    $("set-boot-mode").value = boot.mode || "auto";
    $("set-boot-disk").value = boot.disk || "";
    $("set-boot-esp").value = boot.esp || "";
    $("set-boot-timeout").value = boot.timeout != null ? boot.timeout : 5;
    toggleStaticOnly();
    toggleEspOnly();

    const bits = [];
    bits.push(s.network.mode === "dhcp" ? "сеть: DHCP" : `сеть: ${s.network.ip}/${s.network.prefix}`);
    bits.push(`загрузка: ${boot.mode || "auto"}`);
    bits.push(s.user.name ? `пользователь: ${s.user.name}${s.user.password_set ? " (пароль задан)" : ""}`
                          : "пользователь не задан");
    const ex = Object.entries(s.extras).filter(([, v]) => v).map(([k]) => k);
    bits.push(ex.length ? `доустановить: ${ex.join(", ")}` : "доп. компоненты не выбраны");
    $("settings-state").textContent = "— " + bits.join(" · ");
}

async function loadSettings() {
    try {
        const s = await api("/api/settings");
        fillSettings(s);
    } catch (e) {
        $("settings-state").textContent = "не удалось загрузить настройки";
        console.error(e);
    }
}

async function saveSettings() {
    const msg = $("settings-msg");
    msg.textContent = "сохраняю…";
    const body = {
        network: {
            mode: $("set-net-mode").value,
            iface: $("set-iface").value.trim(),
            ip: $("set-ip").value.trim(),
            prefix: Number($("set-prefix").value) || 24,
            gateway: $("set-gateway").value.trim(),
            dns1: $("set-dns1").value.trim(),
            dns2: $("set-dns2").value.trim(),
        },
        system: {
            hostname: $("set-hostname").value.trim(),
            timezone: $("set-timezone").value.trim(),
            locale: $("set-locale").value.trim(),
            keymap: $("set-keymap").value.trim(),
        },
        user: {
            name: $("set-user").value.trim(),
            groups: $("set-groups").value.trim(),
        },
        extras: {
            nix: $("set-nix").checked,
            ssh: $("set-ssh").checked,
            sudo: $("set-sudo").checked,
            pam: $("set-pam").checked,
            xfce: $("set-xfce").checked,
        },
        boot: {
            mode: $("set-boot-mode").value,
            disk: $("set-boot-disk").value.trim(),
            esp: $("set-boot-esp").value.trim(),
            timeout: Number($("set-boot-timeout").value),
        },
    };
    const pwd = $("set-password").value;
    if (pwd) body.user.password = pwd;

    try {
        const r = await api("/api/settings", { method: "PUT", body: JSON.stringify(body) });
        fillSettings(r.settings);
        msg.textContent = "✓ сохранено " + new Date().toLocaleTimeString();
        setTimeout(() => { msg.textContent = ""; }, 4000);
    } catch (e) {
        let text = e.message || String(e);
        try { text = JSON.parse(text).detail || text; } catch (_) {}
        msg.textContent = "✗ " + text;
    }
}

$("settings-save").onclick = saveSettings;
$("set-net-mode").onchange = toggleStaticOnly;
$("set-boot-mode").onchange = toggleEspOnly;
loadSettings();

// При загрузке всегда цепляемся к самой свежей сборке на сервере.
// localStorage не используем: там мог остаться идентификатор старой сборки,
// из-за чего страница показывала не то, что выполняется сейчас.
attachToLatest();
