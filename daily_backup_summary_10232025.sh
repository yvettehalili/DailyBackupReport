#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
DB_USER="trtel.backup"
DB_PASS="Telus2017#"
DB_NAME="ti_db_inventory"
REPORT_DATE=$(date -d "yesterday" '+%Y-%m-%d')
DIR="backup"
mkdir -p "${DIR}"
emailFile="${DIR}/daily_backup_report.html"

# --- API Configuration ---
QUICKCHART_API="https://quickchart.io/chart/create"

# === HELPER FUNCTION: POST JSON and Get Short URL ===
post_chart_json() {
    local json_payload="${1}"
    local width="${2:-350}"
    local height="${3:-350}"
    local background_color="${4:-white}"

    local URL
    URL=$(curl -s -X POST "${QUICKCHART_API}" \
        -H "Content-Type: application/json" \
        -d "{ \"chart\": ${json_payload}, \"width\": ${width}, \"height\": ${height}, \"backgroundColor\": \"${background_color}\" }" \
        | jq -r '.url')

    if [[ -z "$URL" || "$URL" == "null" ]]; then
        echo "https://via.placeholder.com/${width}x${height}.png/CC0000/FFFFFF?text=CHART+RENDER+FAILED"
    else
        echo "$URL"
    fi
}

# === EXECUTIVE METRICS ===
read total_count error_count <<< $(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT COUNT(*), SUM(IF(size = 0.00 AND size_name = 'B', 1, 0))
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}';
")

success_count=$((total_count - error_count))
success_rate=$(awk "BEGIN {if (${total_count} == 0) {printf \"0.0\"} else {printf \"%.1f\", (${success_count}/${total_count})*100}}")
error_rate=$(awk "BEGIN {if (${total_count} == 0) {printf \"0.0\"} else {printf \"%.1f\", (${error_count}/${total_count})*100}}")

total_storage=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT ROUND(SUM(CASE size_name
    WHEN 'B' THEN size/1024/1024/1024
    WHEN 'KB' THEN size/1024/1024
    WHEN 'MB' THEN size/1024
    WHEN 'GB' THEN size
    ELSE 0 END), 2)
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}';
")

# === BAR CHART DATA ===
engine_storage=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT DB_engine, ROUND(SUM(CASE size_name
    WHEN 'B' THEN size/1024/1024/1024
    WHEN 'KB' THEN size/1024/1024
    WHEN 'MB' THEN size/1024
    WHEN 'GB' THEN size
    ELSE 0 END), 1) AS TotalGB
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}'
GROUP BY DB_engine;
")

LABELS=()
DATA=()
COLORS=()

while IFS=$'\t' read -r engine total; do
  if [[ -z "$engine" ]]; then continue; fi
  LABELS+=("$engine")
  DATA+=("$total")
  case "$engine" in
    MYSQL) COLOR_CODE="#6A4C93" ;;  # TELUS purple variant
    PGSQL) COLOR_CODE="#00A6A6" ;;
    MSSQL) COLOR_CODE="#8BC34A" ;;  # TELUS green
    ORACLE) COLOR_CODE="#FF7043" ;;
    *) COLOR_CODE="#B0BEC5" ;;
  esac
  COLORS+=("$COLOR_CODE")
done <<< "$(echo "${engine_storage}" | tr -d '\r')"

LABELS_JSON=$(printf '%s\n' "${LABELS[@]}" | jq -Rsc 'split("\n")[:-1]')
DATA_JSON=$(printf '%s\n' "${DATA[@]}" | jq -Rsc 'split("\n")[:-1] | map(tonumber)')
COLORS_JSON=$(printf '%s\n' "${COLORS[@]}" | jq -Rsc 'split("\n")[:-1]')

# === DONUT CHART CONFIG ===
DONUT_CHART_JSON=$(jq -n \
  --arg success_rate "$success_rate" \
  --arg error_rate "$error_rate" \
  --argjson success_count "$success_count" \
  --argjson error_count "$error_count" \
  '{
    type: "doughnut",
    data: {
      labels: ["Success (\($success_rate)%)", "Failure (\($error_rate)%)"],
      datasets: [{
        data: [$success_count, $error_count],
        backgroundColor: ["#4B286D", "#00A6A6"],
        borderColor: "#ffffff",
        borderWidth: 3,
        hoverOffset: 8
      }]
    },
    options: {
      cutout: "70%",
      layout: { padding: 20 },
      plugins: {
        legend: {
          position: "bottom",
          labels: { color: "#4B286D", font: { size: 14, weight: "bold" } }
        },
        datalabels: {
          color: "#00A676",
          font: { size: 20, weight: "bold" },
          formatter: "(value, ctx) => {
            const dataset = ctx.chart.data.datasets[0].data;
            const total = dataset.reduce((a,b) => a + b, 0);
            const percentage = Math.round((value / total) * 100);
            return percentage + '%';
          }"
        },
        title: {
          display: true,
          text: "Backup Success Rate",
          color: "#4B286D",
          font: { size: 18, weight: "bold" },
          padding: { bottom: 10 }
        }
      }
    }
  }')

# === BAR CHART CONFIG (Title above but spaced properly) ===
BAR_CHART_JSON=$(jq -n \
  --argjson LABELS "$LABELS_JSON" \
  --argjson DATA "$DATA_JSON" \
  --argjson COLORS "$COLORS_JSON" \
  '{
    type: "bar",
    data: {
      labels: $LABELS,
      datasets: [{
        label: "",
        data: $DATA,
        backgroundColor: $COLORS,
        borderRadius: 10,
        borderWidth: 2,
        borderColor: "#ffffff"
      }]
    },
    options: {
      layout: { padding: { top: 50, bottom: 30 } },
      scales: {
        y: { beginAtZero: true, grid: { color: "#EDE7F6" } },
        x: { grid: { display: false } }
      },
      plugins: {
        legend: { display: false },
        datalabels: {
          anchor: "end",
          align: "end",
          color: "#4B286D",
          font: { weight: "bold", size: 14 },
          formatter: "(value) => value.toFixed(1)"
        },
        title: {
          display: true,
          text: "Total Storage (GB)",
          position: "top",
          color: "#4B286D",
          font: { size: 16, weight: "bold" },
          padding: { bottom: 10 }
        }
      }
    }
  }')

# === CHART URL GENERATION ===
DONUT_CHART_URL=$(post_chart_json "${DONUT_CHART_JSON}" 350 350 white)
BAR_CHART_URL=$(post_chart_json "${BAR_CHART_JSON}" 500 350 white)

# === TOP 5 LARGEST BACKUPS ===
top_backups=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -e "
SELECT Server, DB_engine, CONCAT(ROUND(SUM(
  CASE size_name
    WHEN 'B'  THEN size / 1024 / 1024
    WHEN 'KB' THEN size / 1024
    WHEN 'MB' THEN size
    WHEN 'GB' THEN size * 1024
    ELSE 0
  END
), 2), ' MB') AS TotalSize
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}'
GROUP BY Server, DB_engine
ORDER BY SUM(
  CASE size_name
    WHEN 'B'  THEN size / 1024 / 1024
    WHEN 'KB' THEN size / 1024
    WHEN 'MB' THEN size
    WHEN 'GB' THEN size * 1024
    ELSE 0
  END
) DESC
LIMIT 5;
")

# === EMAIL HTML ===
{
echo "<!DOCTYPE html><html><head><meta charset='UTF-8'><style>
body { font-family: 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f4fb; color: #333; padding: 40px 0; }
.container { max-width: 850px; margin: auto; background: linear-gradient(180deg, #ffffff 0%, #faf7ff 100%); border-radius: 15px; padding: 30px; box-shadow: 0 6px 18px rgba(75, 40, 109, 0.15); }
h1 { text-align: center; color: #4B286D; margin-bottom: 5px; }
.subtitle { text-align: center; color: #777; font-size: 14px; margin-bottom: 20px; }
.summary-box { display: flex; justify-content: space-around; background-color: #f7f3fb; border-radius: 10px; padding: 15px; margin-bottom: 25px; border-left: 6px solid #4B286D; }
.summary-item { text-align: center; }
.summary-item span { display: block; font-size: 22px; color: #4B286D; font-weight: bold; }
.summary-item label { color: #666; font-size: 13px; }
table { width: 100%; border-collapse: collapse; margin-top: 20px; border-radius: 10px; overflow: hidden; box-shadow: 0 0 8px rgba(0,0,0,0.05); }
th { background-color: #4B286D; color: white; padding: 10px; text-align: left; }
td { padding: 10px; border-bottom: 1px solid #ddd; border-right: 1px solid #eee; color: #444; font-size: 14px; }
tr:nth-child(even) td { background-color: #f9f7fc; }
.chart-row { display: flex; flex-wrap: wrap; justify-content: center; gap: 20px; margin-top: 10px; }
.chart-frame { flex: 1 1 45%; background: white; border-radius: 10px; box-shadow: 0 0 8px rgba(0,0,0,0.05); padding: 10px; text-align: center; }
.footer { text-align: center; margin-top: 30px; color: #999; font-size: 13px; }
</style></head><body>
<div class='container'>
<h1>Daily Backup Report</h1>
<div class='subtitle'>Report Date: ${REPORT_DATE}</div>

<div class='summary-box'>
  <div class='summary-item'><span>${success_rate}%</span><label>Success Rate</label></div>
  <div class='summary-item'><span>${error_count}</span><label>Failures</label></div>
  <div class='summary-item'><span>${total_storage} GB</span><label>Total Storage</label></div>
</div>

<div class='chart-row'>
  <div class='chart-frame'><img src='${DONUT_CHART_URL}' style='max-width:100%;'></div>
  <div class='chart-frame'><img src='${BAR_CHART_URL}' style='max-width:100%;'></div>
</div>

<h2 style='text-align:center; color:#4B286D; margin-top:30px;'>Top 5 Largest Backups</h2>
<table>
<tr><th>Server</th><th>Database Engine</th><th>Size</th></tr>"
echo "${top_backups}" | tail -n +2 | while IFS=$'\t' read -r server engine size; do
  echo "<tr><td>${server}</td><td>${engine}</td><td>${size}</td></tr>"
done
echo "</table>
<div class='footer'>Report generated automatically by <b>Database Engineering</b></div>
</div></body></html>"
} > "${emailFile}"

# === SEND EMAIL ===
{
echo "To: yvette.halili@telusinternational.com"
echo "From: no-reply@telusinternational.com"
echo "MIME-Version: 1.0"
echo "Content-Type: text/html; charset=utf-8"
echo "Subject: Daily Backup Report - ${REPORT_DATE}"
echo ""
cat "${emailFile}"
} | /usr/sbin/sendmail -t

echo " Email sent successfully to yvette.halili@telusinternational.com"

