/**
 * Exact Restore KPI hub for Google Sheets.
 *
 * Receives KPI events from every Exact Restore station (POST) and serves them
 * as JSON to external websites (GET). Setup steps are in README.md next to this file.
 */

const EVENTS_SHEET = 'Events';
const SUMMARY_SHEET = 'Summary';
const HEADERS = [
  'id', 'finished_at', 'date', 'employee', 'station', 'kind', 'result', 'port', 'ecid',
  'device_type', 'device_name', 'ipsw', 'activation', 'duration_seconds', 'error', 'started_at'
];
// Stations resend a batch if they never got a confirmation, so recent ids are checked to avoid duplicates.
const DEDUPE_WINDOW = 5000;

// ---------- Receive events from stations ----------

function doPost(e) {
  if (!authorized_(e)) return json_({ ok: false, error: 'Unauthorized' });

  let body;
  try {
    body = JSON.parse(e.postData.contents);
  } catch (err) {
    return json_({ ok: false, error: 'Invalid JSON' });
  }

  const events = Array.isArray(body.events) ? body.events : [];
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);

  try {
    const sheet = eventsSheet_();
    const known = recentIds_(sheet);
    const rows = [];

    events.forEach(function (ev) {
      if (!ev || !ev.id || known.has(ev.id)) return;
      known.add(ev.id);
      const finished = new Date(ev.finishedAt);
      rows.push([
        ev.id,
        finished,
        new Date(finished.getFullYear(), finished.getMonth(), finished.getDate()),
        ev.employee || '',
        ev.station || body.station || '',
        ev.kind || '',
        ev.result || '',
        ev.port || '',
        ev.ecid || '',
        ev.deviceType || '',
        ev.deviceName || '',
        ev.ipsw || '',
        ev.activation || '',
        Number(ev.durationSeconds) || 0,
        ev.error || '',
        ev.startedAt ? new Date(ev.startedAt) : ''
      ]);
    });

    if (rows.length) {
      sheet.getRange(sheet.getLastRow() + 1, 1, rows.length, HEADERS.length).setValues(rows);
    }
    return json_({ ok: true, received: events.length, added: rows.length });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

// ---------- Serve data to websites ----------

/**
 * GET <web app URL>?key=SECRET&view=summary&from=2026-10-01&to=2026-10-14&groupBy=day
 *   view     summary (default) or events
 *   from/to  optional dates, inclusive (yyyy-mm-dd)
 *   groupBy  employee (default) or day   (summary only)
 *   station  optional, only one station
 *   employee optional, only one employee
 */
function doGet(e) {
  if (!authorized_(e)) return json_({ ok: false, error: 'Unauthorized' });

  const p = e.parameter;
  const events = readEvents_().filter(function (ev) {
    if (p.from && ev.date < p.from) return false;
    if (p.to && ev.date > p.to) return false;
    if (p.station && ev.station !== p.station) return false;
    if (p.employee && ev.employee !== p.employee) return false;
    return true;
  });

  if (p.view === 'events') return json_({ ok: true, count: events.length, events: events });

  const byDay = p.groupBy === 'day';
  const groups = {};
  events.forEach(function (ev) {
    const key = byDay ? ev.date + '|' + ev.employee : ev.employee;
    const row = groups[key] || (groups[key] = {
      date: byDay ? ev.date : undefined,
      employee: ev.employee,
      dfu: 0, restores: 0, revives: 0, failed: 0, activationLocked: 0
    });
    if (ev.result === 'failed') row.failed++;
    else if (ev.kind === 'dfu') row.dfu++;
    else if (ev.kind === 'restore') row.restores++;
    else if (ev.kind === 'revive') row.revives++;
    if (ev.activation === 'locked') row.activationLocked++;
  });

  return json_({ ok: true, generatedAt: new Date().toISOString(), summary: Object.values(groups) });
}

// ---------- One time setup ----------

/** Run once from the Apps Script editor: creates the sheets, headers and summary tables. */
function setup() {
  eventsSheet_();

  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const summary = ss.getSheetByName(SUMMARY_SHEET) || ss.insertSheet(SUMMARY_SHEET);
  summary.clear();
  summary.getRange('A1').setValue('Today, completed work per employee').setFontWeight('bold');
  summary.getRange('A2').setFormula(
    '=IFERROR(QUERY(Events!A:P,"select D, count(A) where G = \'succeeded\' and C = date \'"&TEXT(TODAY(),"yyyy-mm-dd")&"\' group by D pivot F label D \'Employee\'",1),"No work today yet")'
  );
  summary.getRange('H1').setValue('Last 7 days, completed work per employee').setFontWeight('bold');
  summary.getRange('H2').setFormula(
    '=IFERROR(QUERY(Events!A:P,"select D, count(A) where G = \'succeeded\' and C >= date \'"&TEXT(TODAY()-6,"yyyy-mm-dd")&"\' group by D pivot F label D \'Employee\'",1),"No work yet")'
  );
  summary.getRange('O1').setValue('Last 7 days, failures per employee').setFontWeight('bold');
  summary.getRange('O2').setFormula(
    '=IFERROR(QUERY(Events!A:P,"select D, count(A) where G = \'failed\' and C >= date \'"&TEXT(TODAY()-6,"yyyy-mm-dd")&"\' group by D label D \'Employee\', count(A) \'Failed\'",1),"No failures")'
  );
}

// ---------- Helpers ----------

function authorized_(e) {
  const key = PropertiesService.getScriptProperties().getProperty('API_KEY');
  return Boolean(key) && e && e.parameter && e.parameter.key === key;
}

function eventsSheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(EVENTS_SHEET);
  if (!sheet) sheet = ss.insertSheet(EVENTS_SHEET);
  if (sheet.getLastRow() === 0) {
    sheet.getRange(1, 1, 1, HEADERS.length).setValues([HEADERS]).setFontWeight('bold');
    sheet.setFrozenRows(1);
    sheet.getRange('B:B').setNumberFormat('yyyy-mm-dd hh:mm:ss');
    sheet.getRange('C:C').setNumberFormat('yyyy-mm-dd');
    sheet.getRange('P:P').setNumberFormat('yyyy-mm-dd hh:mm:ss');
  }
  return sheet;
}

function recentIds_(sheet) {
  const last = sheet.getLastRow();
  if (last < 2) return new Set();
  const start = Math.max(2, last - DEDUPE_WINDOW + 1);
  const ids = sheet.getRange(start, 1, last - start + 1, 1).getValues();
  return new Set(ids.map(function (r) { return String(r[0]); }));
}

function readEvents_() {
  const sheet = eventsSheet_();
  const last = sheet.getLastRow();
  if (last < 2) return [];
  const tz = Session.getScriptTimeZone();
  return sheet.getRange(2, 1, last - 1, HEADERS.length).getValues().map(function (r) {
    return {
      id: String(r[0]),
      finishedAt: r[1] instanceof Date ? r[1].toISOString() : String(r[1]),
      date: r[2] instanceof Date ? Utilities.formatDate(r[2], tz, 'yyyy-MM-dd') : String(r[2]),
      employee: r[3], station: r[4], kind: r[5], result: r[6], port: r[7], ecid: r[8],
      deviceType: r[9], deviceName: r[10], ipsw: r[11], activation: r[12],
      durationSeconds: r[13], error: r[14],
      startedAt: r[15] instanceof Date ? r[15].toISOString() : String(r[15])
    };
  });
}

function json_(data) {
  return ContentService.createTextOutput(JSON.stringify(data)).setMimeType(ContentService.MimeType.JSON);
}
