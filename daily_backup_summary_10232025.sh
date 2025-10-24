#!/bin/bash
# === CONFIGURATION ===
DB_USER="trtel.backup"
DB_PASS="Telus2017#"
DB_NAME="ti_db_inventory"
REPORT_DATE=$(date -d "yesterday" '+%Y-%m-%d')
DIR="backup"
mkdir -p "${DIR}"
emailFile="${DIR}/daily_backup_report.html"

# --- helper: ensure required commands exist
for cmd in mysql jq curl sendmail; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' is not installed or not in PATH" >&2
    exit 1
  fi
done

# === EXECUTIVE METRICS ===
read total_count error_count <<< $(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT COUNT(*), SUM(IF(size = 0.00 AND size_name = 'B', 1, 0))
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}';
")

# default to zero if empty
total_count=${total_count:-0}
error_count=${error_count:-0}
success_count=$((total_count - error_count))
success_rate=$(awk "BEGIN {if (${total_count} == 0) {printf \"0.0\"} else {printf \"%.1f\", (${success_count}/${total_count})*100}}")
error_rate=$(awk "BEGIN {if (${total_count} == 0) {printf \"0.0\"} else {printf \"%.1f\", (${error_count}/${total_count})*100}}")

total_storage=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT ROUND(COALESCE(SUM(CASE size_name
    WHEN 'B'  THEN size/1024/1024/1024
    WHEN 'KB' THEN size/1024/1024
    WHEN 'MB' THEN size/1024
    WHEN 'GB' THEN size
    ELSE 0 END),0), 2)
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}';
")
total_storage=${total_storage:-0.00}

# === BUILD DONUT CHART JSON (as a shell string) ===
DONUT_CHART_PAYLOAD=$(cat <<'JSON'
{
  "chart": {
    "type": "doughnut",
    "data": {
      "labels": ["Success_LABEL", "Failure_LABEL"],
      "datasets": [{
        "data": [SUCCESS_VALUE, FAILURE_VALUE],
        "backgroundColor": ["#6A4C93", "#00A6A6"],
        "borderWidth": 2
      }]
    },
    "options": {
      "plugins": {
        "title": {
          "display": true,
          "text": "Backup Status Overview",
          "color": "#4B286D",
          "font": { "size": 18, "weight": "bold" }
        },
        "legend": {
          "position": "bottom",
          "labels": { "color": "#4B286D", "font": { "weight": "bold" } }
        }
      },
      "cutout": "65%"
    }
  },
  "backgroundColor": "white",
  "width": 350,
  "height": 350
}
JSON
)

# substitute values safely
DONUT_CHART_PAYLOAD="${DONUT_CHART_PAYLOAD//SUCCESS_VALUE/${success_count}}"
DONUT_CHART_PAYLOAD="${DONUT_CHART_PAYLOAD//FAILURE_VALUE/${error_count}}"
DONUT_CHART_PAYLOAD="${DONUT_CHART_PAYLOAD//Success_LABEL/Success (${success_rate}%) }"
DONUT_CHART_PAYLOAD="${DONUT_CHART_PAYLOAD//Failure_LABEL/Failure (${error_rate}%) }"

# POST to QuickChart to get a short URL
DONUT_CHART_URL=$(curl -s -X POST "https://quickchart.io/chart/create" \
  -H "Content-Type: application/json" \
  -d "${DONUT_CHART_PAYLOAD}" | jq -r '.url // empty')

# fallback: if empty, create a simple data URL using quickchart static endpoint (rare)
if [ -z "${DONUT_CHART_URL}" ]; then
  DONUT_CHART_URL="https://quickchart.io/chart?c=$(echo "${DONUT_CHART_PAYLOAD}" | jq -sRr @uri)"
fi

# === BAR CHART: Storage per DB Engine (Data Preparation) ===
engine_storage=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT DB_engine,
       ROUND(COALESCE(SUM(CASE size_name
           WHEN 'B'  THEN size/1024/1024/1024
           WHEN 'KB' THEN size/1024/1024
           WHEN 'MB' THEN size/1024
           WHEN 'GB' THEN size
           ELSE 0 END),0), 1) AS TotalGB
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}'
GROUP BY DB_engine
ORDER BY TotalGB DESC;
")

# prepare arrays
LABELS=()
DATA=()
COLORS=()
while IFS=$'\t' read -r engine total; do
  # skip blank lines
  [ -z "${engine}" ] && continue
  LABELS+=("$engine")
  # coerce empty total to 0
  total=${total:-0}
  DATA+=("$total")
  case "$engine" in
    MYSQL) COLORS+=("#6A4C93") ;;
    PGSQL) COLORS+=("#00A6A6") ;;
    MSSQL) COLORS+=("#8BC34A") ;;
    ORACLE) COLORS+=("#FF7043") ;;
    *) COLORS+=("#B0BEC5") ;;
  esac
done <<< "${engine_storage}"

# If no engine rows found, provide a placeholder
if [ ${#LABELS[@]} -eq 0 ]; then
  LABELS=("No Data")
  DATA=(0)
  COLORS=("#B0BEC5")
fi

# convert bash arrays to JSON arrays
LABELS_JSON=$(printf '%s\n' "${LABELS[@]}" | jq -R -s -c 'split("\n")[:-1]')
DATA_JSON=$(printf '%s\n' "${DATA[@]}" | jq -R -s -c 'map(tonumber) | .')
COLORS_JSON=$(printf '%s\n' "${COLORS[@]}" | jq -R -s -c 'split("\n")[:-1]')

# Build bar chart payload using JS function as string for formatter (QuickChart supports this)
BAR_CHART_PAYLOAD=$(cat <<JSON
{
  "chart": {
    "type": "bar",
    "data": {
      "labels": PLACEHOLDER_LABELS,
      "datasets": [{
        "label": "Total Storage (GB)",
        "data": PLACEHOLDER_DATA,
        "backgroundColor": PLACEHOLDER_COLORS,
        "borderRadius": 10
      }]
    },
    "options": {
      "plugins": {
        "title": {
          "display": true,
          "text": "Daily Backup Storage by DB Engine",
          "color": "#4B286D",
          "font": { "size": 20, "weight": "bold" }
        },
        "legend": { "display": false },
        "datalabels": {
          "display": true,
          "color": "#333333",
          "anchor": "end",
          "align": "top",
          "font": { "weight": "bold", "size": 12 },
          "formatter": "function(value) { return value + ' GB'; }"
        }
      },
      "scales": {
        "x": {
          "ticks": {
            "color": "#4B286D",
            "font": { "weight": "bold" }
          },
          "grid": { "display": false }
        },
        "y": {
          "beginAtZero": true,
          "title": {
            "display": true,
            "text": "Storage (GB)",
            "color": "#4B286D",
            "font": { "weight": "bold" }
          },
          "ticks": { "color": "#333333" },
          "grid": { "color": "rgba(200,200,200,0.2)" }
        }
      }
    }
  },
  "backgroundColor": "white",
  "width": 600,
  "height": 350
}
JSON
)

# replace placeholders with actual JSON arrays (safe substitution)
BAR_CHART_PAYLOAD="${BAR_CHART_PAYLOAD//PLACEHOLDER_LABELS/${LABELS_JSON}}"
BAR_CHART_PAYLOAD="${BAR_CHART_PAYLOAD//PLACEHOLDER_DATA/${DATA_JSON}}"
BAR_CHART_PAYLOAD="${BAR_CHART_PAYLOAD//PLACEHOLDER_COLORS/${COLORS_JSON}}"

# POST to QuickChart create endpoint
BAR_CHART_URL=$(curl -s -X POST "https://quickchart.io/chart/create" \
  -H "Content-Type: application/json" \
  -d "${BAR_CHART_PAYLOAD}" | jq -r '.url // empty')

# fallback to static URL if create endpoint failed
if [ -z "${BAR_CHART_URL}" ]; then
  BAR_CHART_URL="https://quickchart.io/chart?c=$(echo "${BAR_CHART_PAYLOAD}" | jq -sRr @uri)"
fi

# === TOP 5 AGGREGATED BACKUPS (Normalized to MB) ===
top_backups=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -e "
SELECT Server,
       DB_engine,
       CONCAT(ROUND(SUM(
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

# === EMAIL HTML REPORT ===
{
echo "<!DOCTYPE html><html><head><meta charset='UTF-8'><style>
body { font-family: 'Helvetica Neue', Arial, sans-serif; background-color: #f4f4f4; color: #333; padding: 20px; }
.container { max-width: 800px; margin: auto; background-color: #fff; padding: 20px; border-radius: 10px; box-shadow: 0 0 12px rgba(75, 40, 109, 0.1); }
h1, h2, h3 { color: #4B286D; text-align: center; }
table {
  width: 100%;
  border-collapse: collapse;
  margin-top: 20px;
  border: 1px solid #e0d6f0;
  border-radius: 8px;
  overflow: hidden;
  box-shadow: 0 0 8px rgba(0,0,0,0.05);
}
th {
  background-color: #4B286D;
  color: white;
  padding: 10px;
  text-align: left;
}
td {
  padding: 10px;
  border-bottom: 1px solid #eee;
}
tr:nth-child(even) { background-color: #f9f9f9; }
.chart-frame {
  border: 1px solid #e0d6f0;
  border-radius: 10px;
  padding: 10px;
  box-shadow: 0 0 8px rgba(0,0,0,0.05);
  background-color: #fff;
}
</style></head><body><div class='container'>"

echo "<h1>Daily Backup Report - ${REPORT_DATE}</h1>"
echo "<div style='padding: 15px; background-color: #f7f3fb; border-left: 5px solid #4B286D; margin-bottom: 20px;'>"
echo "<p><strong>Executive Summary:</strong><br>"
echo "<span style='color: #008000;'>Status: HIGH SUCCESS (${success_rate}%)</span> | Total Failures: ${error_count} | Total Storage: ${total_storage} GB</p>"
echo "</div>"

echo "<table><tr><td class='chart-frame' style='width: 50%; text-align: center;'><img src='${DONUT_CHART_URL}' style='max-width: 100%;'></td>"
echo "<td class='chart-frame' style='width: 50%; text-align: center;'><img src='${BAR_CHART_URL}' style='max-width: 100%;'></td></tr></table>"

echo "<h2>Top 5 Largest Backups</h2><table><tr><th>Server</th><th>Database Engine</th><th>Size</th></tr>"
echo "${top_backups}" | tail -n +2 | while IFS=$'\t' read -r server engine size; do
    echo "<tr><td>${server}</td><td>${engine}</td><td>${size}</td></tr>"
done
echo "</table>"

echo "<div style='text-align: center; margin-top: 30px; color: #4B286D;'>Report generated by Database Engineering</div>"
echo "</div></body></html>"
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

echo "Email sent to yvette.halili@telusinternational.com"
