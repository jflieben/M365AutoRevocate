/* M365AutoRevocate admin console.
   Delegated Entra sign-in via MSAL; calls the Function App admin API (protected
   by Easy Auth + the admin security group). All config values are driven by the
   catalog returned from the API so the UI can never drift from the backend.
   First sign-in shows a setup wizard, then a short callout tour. */
(function () {
  "use strict";

  var CFG = window.AR_AUTH || {};
  var TRIGGERS = ["inactive", "disable", "delete"];
  var el = function (id) { return document.getElementById(id); };
  var gate = el("gate"), gateErr = el("gateError"), gateMsg = el("gateMsg");

  function fail(msg) {
    gate.hidden = false;
    el("app").hidden = true;
    gateErr.hidden = false;
    gateErr.textContent = msg;
  }

  /* ---------- toasts (prominent, dismissible pop-ups) ---------- */
  function showToast(html, type, sticky) {
    var host = el("toasts");
    if (!host) { return null; }
    var t = document.createElement("div");
    t.className = "toast " + (type || "");
    t.innerHTML = '<div class="toast-body">' + html + "</div>" +
      (sticky ? '<button class="toast-close" type="button" aria-label="Dismiss">&times;</button>' : "");
    host.appendChild(t);
    function close() { t.classList.add("out"); setTimeout(function () { if (t.parentNode) { t.parentNode.removeChild(t); } }, 250); }
    if (sticky) { t.querySelector(".toast-close").onclick = close; } else { setTimeout(close, 7000); }
    return t;
  }
  var lastPermToastKey = "";

  if (typeof msal === "undefined") { fail("Could not load the sign-in library (MSAL). Check your network / content filtering."); return; }
  if (!CFG.clientId || CFG.clientId.indexOf("REPLACE") === 0) {
    fail("Sign-in is not configured yet (authConfig.js still has placeholders). Finish the deployment step that writes it.");
    return;
  }

  var msalInstance = new msal.PublicClientApplication({
    auth: {
      clientId: CFG.clientId,
      authority: "https://login.microsoftonline.com/" + CFG.tenantId,
      redirectUri: window.location.origin + window.location.pathname
    },
    cache: { cacheLocation: "sessionStorage" }
  });
  // MSAL v3+ requires initialize() to complete before any other API call. All
  // sign-in actions and the startup flow chain off this promise.
  var initPromise = msalInstance.initialize();
  var loginRequest = { scopes: [CFG.apiScope] };
  var catalog = [];

  function setAccount(acc) { if (acc) { msalInstance.setActiveAccount(acc); } }

  function currentAccount() {
    var acc = msalInstance.getActiveAccount();
    if (acc) { return acc; }
    var all = msalInstance.getAllAccounts();
    return all && all.length ? all[0] : null;
  }

  function getToken() {
    var acc = currentAccount();
    return msalInstance.acquireTokenSilent({ scopes: [CFG.apiScope], account: acc })
      .then(function (r) { return r.accessToken; })
      .catch(function () { return msalInstance.acquireTokenRedirect(loginRequest); });
  }

  function api(path, method, body) {
    return getToken().then(function (token) {
      return fetch(CFG.apiBase.replace(/\/$/, "") + path, {
        method: method || "GET",
        headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" },
        body: body ? JSON.stringify(body) : undefined
      }).then(function (res) {
        if (res.status === 401 || res.status === 403) { throw new Error("You are not authorised (not a member of the admin group)."); }
        return res.json().catch(function () { return {}; }).then(function (data) {
          if (!res.ok) { throw new Error(data.error || ("API error " + res.status)); }
          return data;
        });
      });
    });
  }

  /* ---------- tabs ---------- */
  function activateTab(name) {
    document.querySelectorAll(".tab").forEach(function (x) { x.classList.toggle("active", x.dataset.tab === name); });
    document.querySelectorAll(".tabpanel").forEach(function (p) { p.hidden = p.id !== "tab-" + name; });
    if (name === "diag") { loadStatus(); }
  }

  /* ---------- rendering ---------- */
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }

  function optInput(featKey, opt) {
    var id = "opt_" + featKey + "_" + opt.key;
    var control = (opt.type === "multiline")
      ? '<textarea id="' + id + '" rows="2"></textarea>'
      : '<input id="' + id + '" type="' + (opt.type === "email" ? "email" : "text") + '" />';
    return '<div class="opt"><label for="' + id + '">' + esc(opt.label) + "</label>" + control + "</div>";
  }

  function checkboxCell(featKey, trig, supports, checked) {
    var supported = supports.indexOf(trig) !== -1;
    var cls = supported ? "" : ' class="disabled-cell"';
    var attrs = supported ? "" : " disabled";
    var title = supported ? "" : ' title="Not possible at this stage"';
    return "<td" + cls + ' style="text-align:center"><input type="checkbox" data-feat="' + featKey +
      '" data-trig="' + trig + '"' + (checked ? " checked" : "") + attrs + title + "></td>";
  }

  function trigProp(trig) { return "at" + trig.charAt(0).toUpperCase() + trig.slice(1); }

  function renderMatrix(cat, config) {
    catalog = cat;
    var rows = "";
    cat.forEach(function (f) {
      var fc = (config.features && config.features[f.key]) || {};
      rows += "<tr><td class='feat-name'>" + esc(f.label) +
        "<div class='feat-desc'>" + esc(f.description) + "</div>";
      (f.options || []).forEach(function (o) { rows += optInput(f.key, o); });
      rows += "</td>";
      TRIGGERS.forEach(function (t) { rows += checkboxCell(f.key, t, f.supports, !!fc[trigProp(t)]); });
      rows += "</tr>";
    });
    el("featureRows").innerHTML = rows;
    // First render: swap the loading spinner for the table and enable Preview.
    if (el("matrixLoading")) { el("matrixLoading").hidden = true; }
    if (el("matrixWrap")) { el("matrixWrap").hidden = false; }
    if (el("previewBtn")) { el("previewBtn").disabled = false; }

    cat.forEach(function (f) {
      var fc = (config.features && config.features[f.key]) || {};
      (f.options || []).forEach(function (o) {
        var input = el("opt_" + f.key + "_" + o.key);
        if (input) { input.value = fc[o.key] == null ? (o.default || "") : fc[o.key]; }
      });
    });

    el("mode").value = config.mode || "soft";
    el("dryRun").value = String(config.dryRun !== false);
    el("servicedeskEmail").value = config.servicedeskEmail || "";
    el("toolName").value = config.toolName || "M365AutoRevocate";
    el("logRetentionDays").value = config.logRetentionDays || 365;
    el("allowExternalForward").value = String(!!config.allowExternalForward);
    el("versionNotify").value = String(!config.versionCheck || config.versionCheck.notifyServicedesk !== false);
    var ina = config.inactive || {};
    el("inactiveEnabled").value = String(!!ina.enabled);
    el("inactiveDays").value = ina.thresholdDays || 90;
    var grp = el("inactiveExclusionGroup");
    grp.value = ina.exclusionGroupName || "";
    grp.dataset.valid = "true";   // came from the server, already resolved
    grp.dataset.groupId = ina.exclusionGroupId || "";
    grp.classList.remove("invalid");
    el("excludeSharedMailboxes").value = String(ina.excludeSharedMailboxes !== false);
    var sf = config.safety || {};
    el("safetyEnabled").value = String(sf.enabled !== false);
    el("capInactive").value = sf.dailyCapInactive == null ? 25 : sf.dailyCapInactive;
    el("capDisable").value = sf.dailyCapDisable == null ? 100 : sf.dailyCapDisable;
    el("capDelete").value = sf.dailyCapDelete == null ? 100 : sf.dailyCapDelete;
    el("percentCeiling").value = sf.percentCeiling == null ? 20 : sf.percentCeiling;
    syncInactiveFields();
  }

  function syncInactiveFields() {
    // Only the inactive-after threshold is gated by the monitoring toggle. The
    // exclusion group and shared-mailbox exclusion are GLOBAL (they apply to
    // disable/delete too), so they stay editable regardless.
    el("inactiveDays").disabled = el("inactiveEnabled").value !== "true";
  }

  /* ---------- projected-changes preview (modal) ---------- */
  function fmtDate(s) {
    if (!s) { return "-"; }
    var d = new Date(s);
    return isNaN(d.getTime()) ? "-" : d.toISOString().slice(0, 10);
  }

  // Coerce to an array: a single-element PowerShell collection can serialise as a
  // bare value, so a list field may arrive as a scalar (or be absent).
  function asArray(v) { return v == null ? [] : (Array.isArray(v) ? v : [v]); }

  function previewGroupHtml(title, block, columns) {
    var html = '<div class="preview-group"><h3>' + esc(title) + "</h3>";
    if (!block || !block.applicable) {
      html += '<div class="preview-empty">' + esc((block && block.note) || "Not applicable.") + "</div></div>";
      return html;
    }
    var actions = asArray(block.actions);
    if (actions.length) {
      html += '<div class="preview-group-actions">Will run: ' + actions.map(esc).join(", ") + "</div>";
    }
    var countTxt = (block.sampled ? "at least " : "") + block.count + " account(s) will be actioned";
    html += '<div class="preview-summary">' + esc(countTxt) + ".</div>";
    asArray(block.notes).forEach(function (n) { html += '<div class="preview-note">' + esc(n) + "</div>"; });
    if (!block.count) {
      html += '<div class="preview-empty">Nothing to action right now.</div></div>';
      return html;
    }
    html += '<div class="table-wrap"><table class="preview-table"><thead><tr>';
    columns.forEach(function (c) { html += "<th>" + esc(c.label) + "</th>"; });
    html += "</tr></thead><tbody>";
    asArray(block.items).forEach(function (it) {
      html += "<tr>";
      columns.forEach(function (c) { html += "<td>" + esc(c.get(it)) + "</td>"; });
      html += "</tr>";
    });
    html += "</tbody></table></div>";
    if (block.truncated) {
      html += '<div class="preview-note">Showing the first ' + block.detailCount + " of " + block.count + "; the rest are counted but not listed.</div>";
    }
    return html + "</div>";
  }

  function openPreview() {
    var body = el("previewBody");
    body.innerHTML = '<div class="loading"><span class="spinner" aria-hidden="true"></span> Working out the projected changes…</div>';
    el("previewModal").hidden = false;
    // POST the on-screen (possibly unsaved) config so the preview matches what a
    // Save would do right now.
    api("/preview", "POST", gather()).then(function (d) {
      var t = d.triggers || {};
      var nameCol = { label: "Name", get: function (i) { return i.displayName || ""; } };
      var upnCol = { label: "UPN", get: function (i) { return i.upn || ""; } };
      var createdCol = { label: "Created", get: function (i) { return fmtDate(i.createdDateTime); } };

      var html = "";
      var inaTitle = "Inactive users" +
        (t.inactive && t.inactive.applicable ? " (inactive after " + t.inactive.thresholdDays + " days)" : "");
      html += previewGroupHtml(inaTitle, t.inactive, [
        nameCol, upnCol, createdCol,
        { label: "Last sign-in", get: function (i) { return i.lastSignIn ? fmtDate(i.lastSignIn) : "never"; } }
      ]);

      html += previewGroupHtml("Disabled accounts", t.disable, [nameCol, upnCol, createdCol]);

      var delCols = [nameCol, upnCol, createdCol, { label: "Deleted", get: function (i) { return fmtDate(i.deletedDateTime); } }];
      if (t.delete && t.delete.mode === "hard") {
        delCols.push({ label: "Acts on", get: function (i) { return fmtDate(i.dueDate); } });
      }
      var delTitle = "Deleted accounts" + (t.delete && t.delete.mode ? " (" + t.delete.mode + " delete)" : "");
      html += previewGroupHtml(delTitle, t.delete, delCols);

      body.innerHTML = html;
    }).catch(function (e) {
      body.innerHTML = '<div class="error">Could not build the preview: ' + esc(e.message) + "</div>";
    });
  }

  function closePreview() { el("previewModal").hidden = true; }

  function gather() {
    var features = {};
    catalog.forEach(function (f) {
      var entry = {};
      TRIGGERS.forEach(function (t) {
        var cb = document.querySelector('input[data-feat="' + f.key + '"][data-trig="' + t + '"]');
        entry[trigProp(t)] = !!(cb && cb.checked && !cb.disabled);
      });
      (f.options || []).forEach(function (o) {
        var input = el("opt_" + f.key + "_" + o.key);
        entry[o.key] = input ? input.value : (o.default || "");
      });
      features[f.key] = entry;
    });
    return {
      mode: el("mode").value,
      dryRun: el("dryRun").value === "true",
      servicedeskEmail: el("servicedeskEmail").value,
      toolName: el("toolName").value,
      logRetentionDays: parseInt(el("logRetentionDays").value, 10) || 365,
      allowExternalForward: el("allowExternalForward").value === "true",
      versionCheck: { notifyServicedesk: el("versionNotify").value === "true" },
      inactive: {
        enabled: el("inactiveEnabled").value === "true",
        thresholdDays: parseInt(el("inactiveDays").value, 10) || 90,
        exclusionGroupId: el("inactiveExclusionGroup").dataset.groupId || "",
        exclusionGroupName: el("inactiveExclusionGroup").value.trim(),
        excludeSharedMailboxes: el("excludeSharedMailboxes").value === "true"
      },
      safety: {
        enabled: el("safetyEnabled").value === "true",
        dailyCapInactive: parseInt(el("capInactive").value, 10),
        dailyCapDisable: parseInt(el("capDisable").value, 10),
        dailyCapDelete: parseInt(el("capDelete").value, 10),
        percentCeiling: parseInt(el("percentCeiling").value, 10)
      },
      features: features
    };
  }

  function renderLogs(items) {
    var tb = el("logRows");
    el("logEmpty").hidden = items.length > 0;
    tb.innerHTML = items.map(function (i) {
      var trigCls = i.trigger === "delete" ? "delete"
        : i.trigger === "inactive" ? "inactive"
          : i.trigger === "system" ? "" : "disable";
      var pill = '<span class="pill ' + trigCls + '">' + esc(i.trigger) + "</span>";
      var dry = (String(i.dryRun).toLowerCase() === "true") ? ' <span class="pill dry">dry run</span>' : "";
      var when = i.timestamp ? new Date(i.timestamp).toISOString().replace("T", " ").replace(/\..*/, "") : "";
      // Name only in the column; UPN and object id live in the hover tooltip so
      // the column never grows wide.
      var name = i.displayName || i.upn || i.userId || "";
      var hover = [i.upn, i.userId].filter(function (x) { return x && x !== name; }).join("\n");
      var userCell = hover
        ? '<span class="user-cell" title="' + esc(hover) + '">' + esc(name) + "</span>"
        : esc(name);
      return "<tr><td>" + esc(when) + "</td><td>" + userCell + "</td><td>" + pill + "</td><td>" + esc(i.event) +
        "</td><td>" + dry + "</td><td><details><summary>view</summary><pre style='white-space:pre-wrap'>" +
        esc(prettyJson(i.summary)) + "</pre></details></td></tr>";
    }).join("");
  }

  /* ---------- activity log paging + filters ---------- */
  var logState = { items: [], ct: "" };

  function applyLogSearch(items) {
    var q = el("logSearch").value.trim().toLowerCase();
    if (!q) { return items; }
    return items.filter(function (i) {
      return [i.displayName, i.upn, i.userId, i.event, i.trigger].join(" ").toLowerCase().indexOf(q) !== -1;
    });
  }

  function loadLogs(append) {
    if (!append) { logState.items = []; logState.ct = ""; }
    var q = "/logs?top=50";
    var trig = el("logTrigger").value;
    if (trig) { q += "&trigger=" + encodeURIComponent(trig); }
    if (append && logState.ct) { q += "&ct=" + encodeURIComponent(logState.ct); }
    el("logMore").disabled = true;
    return api(q).then(function (d) {
      logState.items = logState.items.concat(d.items || []);
      logState.ct = d.nextCt || "";
      el("logMore").hidden = !logState.ct;
      renderLogs(applyLogSearch(logState.items));
    }).finally(function () { el("logMore").disabled = false; });
  }

  function prettyJson(s) { try { return JSON.stringify(JSON.parse(s), null, 2); } catch (e) { return s || ""; } }

  /* ---------- diagnostics ---------- */
  function fmtUtc(s) { return s ? new Date(s).toISOString().replace("T", " ").replace(/\..*/, "") : "-"; }

  function hoursAgo(s) {
    if (!s) { return null; }
    return Math.round((Date.now() - new Date(s).getTime()) / 3600000);
  }

  /* ---------- global banners (dry-run simulation + storm-guard pause) ---------- */
  function renderBanners(d) {
    var host = el("banners");
    if (!host) { return; }
    var html = "";
    var safety = d.safety || {};
    if (safety.paused) {
      html += '<div class="banner err"><div><strong>Processing is paused</strong> by the storm guard. ' +
        'No offboarding actions are running. ' + esc(safety.pausedReason || "") +
        '</div><button id="resumeBtn" class="btn primary">Review &amp; resume</button></div>';
    }
    if (d.dryRun) {
      html += '<div class="banner warn"><div><strong>Simulation mode</strong> (dry run): the tool logs what it would do but changes nothing. ' +
        'Turn it off under <strong>Configuration &rarr; Simulation mode</strong> when you are confident.</div></div>';
    }
    var poison = d.queues && d.queues.poison;
    if (poison && poison > 0) {
      html += '<div class="banner err"><div><strong>' + poison + ' message(s) in the poison queue.</strong> ' +
        'These cleanups failed repeatedly. Check the Diagnostics tab and Application Insights.</div></div>';
    }
    var vc = d.versionCheck;
    if (vc && vc.updateAvailable && vc.latest) {
      var relLink = vc.releasesUrl
        ? '<a href="' + esc(vc.releasesUrl) + '" target="_blank" rel="noopener">release notes</a>'
        : "the repository";
      html += '<div class="banner info"><div><strong>Update available: v' + esc(vc.latest) + '</strong> ' +
        "(you are on v" + esc(vc.installed || "?") + "). Re-run the deployment to update. See " + relLink + ".</div></div>";
    }
    host.innerHTML = html;

    // Missing permissions are shown as a prominent toast (not a quiet banner),
    // once per distinct set, so a newly-enabled action's missing role is obvious.
    var missing = (d.permissions || []).filter(function (p) { return !p.granted; });
    var key = missing.map(function (p) { return p.role; }).sort().join(",");
    if (missing.length && key !== lastPermToastKey) {
      lastPermToastKey = key;
      showToast("<strong>Missing Graph permission(s):</strong> " +
        missing.map(function (p) { return "<code>" + esc(p.role) + "</code>"; }).join(", ") +
        ".<br>Actions needing these will fail until an admin consents them on the Function App's enterprise application.",
        "err", true);
    } else if (!missing.length) {
      lastPermToastKey = "";
    }
    var rb = el("resumeBtn");
    if (rb) {
      rb.onclick = function () {
        rb.disabled = true;
        rb.textContent = "Resuming…";
        api("/resume", "POST", {}).then(function () { return loadStatus(); }).then(function () {
          loadLogs(false);
        }).catch(function (e) {
          rb.disabled = false;
          rb.textContent = "Review & resume";
          alert(e.message);
        });
      };
    }
  }

  function renderStatus(d) {
    renderBanners(d);
    if (el("appVersion") && d.version) {
      var vtxt = "v" + d.version;
      if (d.versionCheck && d.versionCheck.updateAvailable && d.versionCheck.latest) {
        vtxt += " (update: v" + d.versionCheck.latest + ")";
      }
      el("appVersion").textContent = vtxt;
    }
    var sub = d.subscription || { status: "unknown" };
    var healthy = sub.status === "active";
    var pillCls = healthy ? "ok" : (sub.status === "expiring" ? "warnp" : "errp");
    var summary = healthy
      ? "Healthy: change notifications for user updates and deletions are being received."
      : sub.status === "expiring"
        ? "Expiring soon; it should renew automatically within the hour."
        : "NOT healthy: deletions/disables are not being received. Check the SubscriptionManager row below.";
    el("subHealth").innerHTML = '<span class="pill ' + pillCls + '">' + esc(sub.status) + "</span> " + esc(summary) +
      (sub.error ? ' <span class="error">' + esc(sub.error) + "</span>" : "");

    var detailsBtn = el("subDetailsBtn");
    var details = el("subDetails");
    if (sub.id) {
      details.innerHTML = '<table class="kv">' +
        "<tr><td>Subscription id</td><td><code>" + esc(sub.id) + "</code></td></tr>" +
        "<tr><td>Resource</td><td><code>" + esc(sub.resource) + "</code> (" + esc(sub.changeType) + ")</td></tr>" +
        "<tr><td>Expires</td><td>" + esc(fmtUtc(sub.expirationDateTime)) + " UTC (" + esc(sub.hoursUntilExpiry) + "h left; auto-renewed ~6-hourly)</td></tr>" +
        "<tr><td>Callback</td><td><code>" + esc(sub.notificationUrl) + "</code></td></tr>" +
        "</table>";
      detailsBtn.hidden = false;
      detailsBtn.onclick = function () {
        details.hidden = !details.hidden;
        detailsBtn.textContent = details.hidden ? "Show details" : "Hide details";
      };
    } else {
      detailsBtn.hidden = true;
      details.hidden = true;
      details.innerHTML = "";
    }

    el("fnRows").innerHTML = (d.functions || []).map(function (f) {
      var st = f.status === "ok" ? '<span class="pill ok">ok</span>'
        : f.status === "error" ? '<span class="pill errp">error</span>'
          : '<span class="pill">' + esc(f.status) + "</span>";
      var err = f.lastError
        ? "<details><summary>" + esc(fmtUtc(f.lastErrorUtc)) + "</summary><pre style='white-space:pre-wrap'>" + esc(f.lastError) + "</pre></details>"
        : "-";
      var dur = f.durationMs ? (f.durationMs + " ms") : "-";
      var name = f.portalUrl
        ? '<a href="' + esc(f.portalUrl) + '" target="_blank" rel="noopener" title="View invocations in the Azure portal">' + esc(f.name) + "</a>"
        : esc(f.name);
      return "<tr><td>" + name + "</td><td>" + st + "</td><td>" + esc(fmtUtc(f.lastRun)) + "</td><td>" + dur + "</td><td>" + err + "</td></tr>";
    }).join("");

    if (el("snapshotAge")) {
      var ha = hoursAgo(d.snapshotUtc);
      el("snapshotAge").innerHTML = d.snapshotUtc
        ? ("Directory snapshot last updated " + esc(fmtUtc(d.snapshotUtc)) + " UTC (" + ha + "h ago)" + (ha > 48 ? ' <span class="pill errp">stale</span>' : ""))
        : "Directory snapshot has not run yet.";
    }
    if (el("safetyCounts") && d.safety && d.safety.counts) {
      var c = d.safety.counts, caps = d.safety.caps || {};
      var q = d.queues || {};
      var qtxt = (q.revocations >= 0 ? " Queue depth: " + q.revocations + "." : "") +
        (q.poison >= 0 ? " Poison: " + q.poison + "." : "");
      el("safetyCounts").textContent = "Actions today - inactive " + c.inactive + "/" + (caps.inactive || 0) +
        ", disable " + c.disable + "/" + (caps.disable || 0) + ", delete " + c.delete + "/" + (caps.delete || 0) + "." + qtxt;
    }
  }

  function loadStatus() {
    el("subHealth").textContent = "Loading…";
    return api("/status").then(renderStatus).catch(function (e) {
      el("subHealth").innerHTML = '<span class="error">' + esc(e.message) + "</span>";
    });
  }

  /* ---------- group picker (autocomplete + validation) ---------- */
  function attachGroupPicker(input) {
    var suggest = input.parentElement.querySelector(".suggest");
    var timer = null;
    input.dataset.valid = "true"; // empty counts as valid (no exclusion)

    function markValid(ok, id) {
      input.dataset.valid = ok ? "true" : "false";
      // The object id is what the server trusts (display names are not unique).
      // Only a picked / exact-matched group has one; typing clears it.
      input.dataset.groupId = ok && id ? id : "";
      input.classList.toggle("invalid", !ok && input.value.trim() !== "");
    }

    function hide() { suggest.hidden = true; suggest.innerHTML = ""; }

    function show(items) {
      if (!items.length) {
        suggest.innerHTML = '<div class="none">No matching security groups</div>';
      } else {
        suggest.innerHTML = items.map(function (g) {
          return '<div class="item" data-name="' + esc(g.displayName) + '" data-id="' + esc(g.id) + '">' + esc(g.displayName) + "</div>";
        }).join("");
        Array.prototype.forEach.call(suggest.querySelectorAll(".item"), function (d) {
          d.onclick = function () {
            input.value = d.dataset.name;
            markValid(true, d.dataset.id);
            hide();
          };
        });
      }
      suggest.hidden = false;
    }

    input.addEventListener("input", function () {
      markValid(input.value.trim() === "", "");   // typing invalidates until a pick or exact match
      clearTimeout(timer);
      var q = input.value.trim();
      if (q.length < 2) { hide(); return; }
      timer = setTimeout(function () {
        api("/groups?search=" + encodeURIComponent(q)).then(function (d) {
          var items = d.items || [];
          show(items);
          // Exact (case-insensitive) match validates (and captures the id)
          // without an explicit click.
          var exact = items.filter(function (g) { return g.displayName.toLowerCase() === q.toLowerCase(); })[0];
          if (exact) { markValid(true, exact.id); }
        }).catch(function () { hide(); });
      }, 250);
    });
    input.addEventListener("blur", function () { setTimeout(hide, 200); });
  }

  function pickerInvalid(input) {
    // Invalid unless empty, OR resolved to a real group id.
    if (input.disabled) { return false; }
    if (input.value.trim() === "") { return false; }
    return input.dataset.valid !== "true" || !input.dataset.groupId;
  }

  /* ---------- setup wizard (first run) ---------- */
  function showWizard(config) {
    el("wizard").hidden = false;
    if (el("wizServicedesk")) { el("wizServicedesk").value = config.servicedeskEmail || ""; }
    if (el("wizVersionNotify")) { el("wizVersionNotify").checked = !config.versionCheck || config.versionCheck.notifyServicedesk !== false; }
    Array.prototype.forEach.call(document.querySelectorAll('input[name="wizDryRun"]'), function (r) {
      r.checked = (r.value === String(config.dryRun !== false));
    });
    Array.prototype.forEach.call(document.querySelectorAll('input[name="wizInactive"]'), function (r) {
      r.onchange = function () {
        el("wizInactiveExtra").hidden = document.querySelector('input[name="wizInactive"]:checked').value !== "true";
      };
    });
    el("wizSave").onclick = function () {
      var err = el("wizError");
      err.hidden = true;
      var monitor = document.querySelector('input[name="wizInactive"]:checked').value === "true";
      if (monitor && pickerInvalid(el("wizExclusionGroup"))) {
        err.textContent = "Pick the exclusion group from the suggestions (it must be an existing Entra security group), or leave it empty.";
        err.hidden = false;
        return;
      }
      var payload = {
        mode: document.querySelector('input[name="wizMode"]:checked').value,
        dryRun: document.querySelector('input[name="wizDryRun"]:checked').value === "true",
        servicedeskEmail: (el("wizServicedesk") ? el("wizServicedesk").value.trim() : "") || config.servicedeskEmail || "",
        inactive: {
          enabled: monitor,
          thresholdDays: parseInt(el("wizDays").value, 10) || 90,
          exclusionGroupId: monitor ? (el("wizExclusionGroup").dataset.groupId || "") : "",
          exclusionGroupName: monitor ? el("wizExclusionGroup").value.trim() : "",
          excludeSharedMailboxes: true
        },
        safety: config.safety || {},
        allowExternalForward: !!config.allowExternalForward,
        versionCheck: { notifyServicedesk: el("wizVersionNotify") ? el("wizVersionNotify").checked : true },
        features: config.features || {}
      };
      el("wizSave").disabled = true;
      api("/config", "POST", payload).then(function (d) {
        el("wizard").hidden = true;
        renderMatrix(d.catalog, d.config);
        activateTab("actions");
        startTour();
      }).catch(function (e) {
        err.textContent = e.message;
        err.hidden = false;
      }).finally(function () { el("wizSave").disabled = false; });
    };
  }

  /* ---------- welcome tour (CSS callouts) ---------- */
  var TOUR_STEPS = [
    { tab: "actions", target: "matrixCard", text: "This is the heart of the tool: tick when each action runs: when a user goes inactive, is disabled, or is deleted. Greyed boxes aren’t possible at that stage. Save when done." },
    { tab: "config", target: "timingCard", text: "Configuration holds the timing (soft vs hard delete), the service desk fallback address, the safety limits, the global exclusions (accounts never touched at any trigger), and inactive-user monitoring." },
    { tab: "log", target: "tabbtn-log", text: "The Activity log shows every action the tool has taken (including dry runs), with full detail per user." },
    { tab: "diag", target: "subCard", text: "Diagnostics shows the Graph subscription health and the last run of every worker function. It is your first stop if something seems off." }
  ];
  var tourIdx = 0;

  function tourTarget(name) {
    if (name.indexOf("tabbtn-") === 0) { return document.querySelector('.tab[data-tab="' + name.substring(7) + '"]'); }
    return el(name);
  }

  function positionCallout(name) {
    var t = tourTarget(name);
    if (!t) { return false; }
    document.querySelectorAll(".tour-highlight").forEach(function (x) { x.classList.remove("tour-highlight"); });
    t.classList.add("tour-highlight");
    t.scrollIntoView({ block: "center", behavior: "smooth" });
    var r = t.getBoundingClientRect();
    var box = el("tourBox");
    var top = r.bottom + 10;
    if (top + 150 > window.innerHeight) { top = Math.max(10, r.top - 160); }
    box.style.top = top + "px";
    box.style.left = Math.max(10, Math.min(r.left, window.innerWidth - 380)) + "px";
    return true;
  }

  function showTourStep() {
    if (tourIdx >= TOUR_STEPS.length) { endTour(); return; }
    var step = TOUR_STEPS[tourIdx];
    activateTab(step.tab);
    el("tour").hidden = false;
    el("tourText").textContent = step.text;
    el("tourStepNo").textContent = (tourIdx + 1) + " / " + TOUR_STEPS.length;
    el("tourNext").textContent = tourIdx === TOUR_STEPS.length - 1 ? "Done" : "Next";
    if (!positionCallout(step.target)) { tourIdx++; showTourStep(); }
  }

  function endTour() {
    el("tour").hidden = true;
    document.querySelectorAll(".tour-highlight").forEach(function (x) { x.classList.remove("tour-highlight"); });
    activateTab("actions");
    try { localStorage.setItem("ar_tour_done", "1"); } catch (e) { /* private mode */ }
  }

  function startTour() {
    try { if (localStorage.getItem("ar_tour_done")) { return; } } catch (e) { /* ignore */ }
    tourIdx = 0;
    el("tourNext").onclick = function () { tourIdx++; showTourStep(); };
    el("tourSkip").onclick = endTour;
    showTourStep();
  }

  /* ---------- actions ---------- */
  function loadConfig() {
    return api("/config").then(function (d) {
      renderMatrix(d.catalog, d.config);
      if (d.firstRun) { showWizard(d.config); }
    });
  }

  function setSaveStatus(text, cls) {
    document.querySelectorAll(".save-status").forEach(function (s) { s.textContent = text; s.className = "status save-status " + (cls || ""); });
  }

  function save() {
    // The exclusion group is global (applies to every trigger), so validate it
    // whenever one is entered, not only when inactive monitoring is on.
    if (pickerInvalid(el("inactiveExclusionGroup"))) {
      setSaveStatus("Pick the exclusion group from the suggestions (must be a real Entra group), or clear it.", "err");
      activateTab("config");
      return;
    }
    setSaveStatus("Saving…", "");
    document.querySelectorAll(".save-btn").forEach(function (b) { b.disabled = true; });
    api("/config", "POST", gather()).then(function (d) {
      renderMatrix(d.catalog, d.config);
      setSaveStatus("Saved.", "ok");
    }).catch(function (e) {
      setSaveStatus(e.message, "err");
    }).finally(function () {
      document.querySelectorAll(".save-btn").forEach(function (b) { b.disabled = false; });
    });
  }

  function showApp() {
    gate.hidden = true;
    el("app").hidden = false;
    var acc = currentAccount();
    el("userName").textContent = acc ? (acc.name || acc.username) : "";
    el("signOutBtn").hidden = false;
    // loadStatus() also renders the global banners (dry-run / paused) and the
    // version, so it runs on startup regardless of which tab is active.
    Promise.all([loadConfig(), loadLogs(), loadStatus()]).catch(function (e) { fail(e.message); });
  }

  function wire() {
    el("gateSignIn").onclick = function () { initPromise.then(function () { msalInstance.loginRedirect(loginRequest); }); };
    el("signOutBtn").onclick = function () { initPromise.then(function () { msalInstance.logoutRedirect(); }); };
    document.querySelectorAll(".save-btn").forEach(function (b) { b.onclick = save; });
    el("refreshLog").onclick = function () { loadLogs(false); };
    el("logMore").onclick = function () { loadLogs(true); };
    el("logTrigger").onchange = function () { loadLogs(false); };
    el("logSearch").oninput = function () { renderLogs(applyLogSearch(logState.items)); };
    el("refreshDiag").onclick = loadStatus;
    el("inactiveEnabled").onchange = syncInactiveFields;
    el("previewBtn").onclick = openPreview;
    el("previewClose").onclick = closePreview;
    el("previewModal").addEventListener("click", function (e) { if (e.target === el("previewModal")) { closePreview(); } });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !el("previewModal").hidden) { closePreview(); } });
    // Confirmation friction: enabling an irreversible action spells out the
    // blast radius before it can be ticked.
    el("featureRows").addEventListener("change", function (e) {
      var cb = e.target;
      if (!cb || !cb.matches || !cb.matches('input[type=checkbox]') || !cb.checked) { return; }
      var destructive = {
        softDeleteUser: "soft-delete the account (move it to the recycle bin)",
        removeFromGroups: "remove the user from every group they belong to",
        removeLicenses: "remove all of the user's directly-assigned licences"
      };
      var what = destructive[cb.dataset.feat];
      if (what && !window.confirm("Enable an irreversible action?\n\nThis will " + what +
        " for every user that reaches the '" + cb.dataset.trig + "' trigger.\n\nMake sure your exclusion group and safety limits are set first. Continue?")) {
        cb.checked = false;
      }
    });
    attachGroupPicker(el("inactiveExclusionGroup"));
    attachGroupPicker(el("wizExclusionGroup"));
    document.querySelectorAll(".tab").forEach(function (t) {
      t.onclick = function () { activateTab(t.dataset.tab); };
    });
  }

  wire();
  initPromise.then(function () {
    return msalInstance.handleRedirectPromise();
  }).then(function (resp) {
    if (resp && resp.account) { setAccount(resp.account); }
    if (currentAccount()) { showApp(); }
    else { gate.hidden = false; gateMsg.textContent = "Sign in with your organisational account to manage offboarding automation."; }
  }).catch(function (e) { fail("Sign-in failed: " + (e && e.message ? e.message : e)); });
})();
