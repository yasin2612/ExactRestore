# Google Sheets KPI hub

Every Exact Restore station sends its KPI records to one Google Sheet. Websites read them back as JSON.

## Set up (once)

1. Create a new Google Sheet, for example **Exact Restore KPIs**.
2. **Extensions > Apps Script**. Delete the sample code and paste all of `Code.gs`. Save.
3. **Project Settings** (gear icon) > **Script properties** > **Add script property**:
   * Property: `API_KEY`
   * Value: a long random secret, for example the output of `uuidgen` in Terminal.
4. Back in the editor, choose the `setup` function in the toolbar and click **Run**. Approve the permissions. This creates the **Events** and **Summary** sheets.
5. **Deploy > New deployment** > type **Web app**:
   * Execute as: **Me**
   * Who has access: **Anyone**
   * Click **Deploy** and copy the **Web app URL** (ends in `/exec`).

"Anyone" only means the URL is reachable. Without the secret key, every request is refused.

## Connect each station

In Exact Restore, **Settings > KPI sync**:
* **API URL:** `<Web app URL>?key=<your API_KEY>`
* **API key:** leave empty (Apps Script cannot read it; the key travels in the URL instead).
* Click **Save and sync now**. Existing local records are sent too.

## Read data from websites

```
GET <Web app URL>?key=<API_KEY>                                   # totals per employee, all time
GET <Web app URL>?key=<API_KEY>&from=2026-10-14&to=2026-10-14     # today
GET <Web app URL>?key=<API_KEY>&from=2026-10-01&groupBy=day       # per employee per day
GET <Web app URL>?key=<API_KEY>&view=events&from=2026-10-14       # raw records
```
Optional filters: `station`, `employee`.

Example response:
```json
{ "ok": true, "summary": [ { "employee": "Employee name", "dfu": 24, "restores": 21, "revives": 2, "failed": 1, "activationLocked": 0 } ] }
```

Call it from a server or backend, not from browser JavaScript, so the key is never visible to visitors.

## Updating the script

After editing `Code.gs`: **Deploy > Manage deployments** > edit (pencil) > Version: **New version** > **Deploy**. The URL stays the same.

## Limits

Apps Script handles a few thousand requests a day comfortably, and a sheet holds about 10 million cells (over 500,000 records). If you get close, move old rows to an archive sheet.
