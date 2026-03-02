# SEPAL 🌱 (Sebastian’s Plant Alert)

A minimal sensor and dashboard for monitoring a plant growth cabinet with **5 layers**.  
Each layer logs **temperature (°C)**, **humidity (%)**, and **light (lux)** to Google Sheets, generates an **AI status update**, and displays everything in a small **static frontend**.

Frontend deployed via github pages: https://setri100.github.io/sepal/

## What it does

- **Sensor Readings:**
    - Reads **DHT21** (temp/humidity) via Linux `iio:device*`
    - Reads **BH1750** (lux) via **TCA9548A I2C multiplexer**
    - Writes one row per cycle into a Google Sheet tab: `data`

- **AI status:**
    - Pulls the last `N` hours from the `data` sheet
    - Computes simple hints (NaNs per sensor, light ON/OFF events)
    - Calls *KI Connect NRW* chat completions to produce 2–3 sentences
    - Appends result into a `status` sheet tab

- **Frontend (static HTML):**
    - Reads published CSV exports of `data` and `status`
    - Shows latest readings, history charts, and detected light switch events


## Sheets layout

### `data` tab (header)
`ts, temp_1, humidity_1, lux_1, ... , temp_5, humidity_5, lux_5`

### `status` tab (header)
`ts_utc, window_hours, ai_status`


## Setup (high level)

1. **Google Sheet**
- Create a sheet with a `data` tab (backend will write header automatically)
- Create a `status` tab (AI script can create it via API if permitted)
- Publish the sheet to the web (CSV export used

2. **Service account**
- Create a Google service account key JSON
- Share the spreadsheet with the service account email

3. **Backend (Python)**
- Installed deps: `adafruit_bh1750`, `adafruit_tca9548a`, `gspread`, `google-auth`    
- Set:
    - `SPREADSHEET_ID`
    - `WORKSHEET_NAME="data"`
    - `CREDS_JSON_PATH`

4. **AI script (bash)**
- Requires: `curl jq python3 awk sed date`
- In the scripts:
    - `SPREADSHEET_ID`
    - `WORKSHEET_NAME="data"`
    - `STATUS_SHEET_NAME="status"`
    - `CREDS_JSON_PATH`
    - `API_URL`, `MODEL_NAME`, `API_KEY`
    - `HOURS_BACK`, `SAMPLE_EVERY_N`, `LIGHT_LUX_THRESHOLD`

5. **Frontend**
    - `index.html` on any static host (or open locally)
    - Set:  
        - `DATA_URL` to the published CSV of the `data` tab
        - `STATUS_GID` (gid of the `status` tab) so `STATUS_URL` works


## Run

- Backend: run on an interval (systemd timer / cron)
- AI status: run on an interval (here every 3 hours)


## Notes

- `NaN` values indicate failed reads (mostly non-connected sensors).
- Lux “light on” detection uses a threshold in the AI script and a separate value in the frontend events panel.




