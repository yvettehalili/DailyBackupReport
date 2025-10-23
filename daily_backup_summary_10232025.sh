#!/bin/bash

# === CONFIGURATION ===
DB_USER="trtel.backup"
DB_PASS="Telus2017#"
DB_NAME="ti_db_inventory"
REPORT_DATE=$(date -d "yesterday" '+%Y-%m-%d')
DIR="backup"
mkdir -p "${DIR}"
emailFile="${DIR}/daily_backup_report.html"
LOG_FILE="${DIR}/debug.log"
: > "${LOG_FILE}"

# === EXECUTIVE METRICS ===
read total_count error_count <<< $(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT COUNT(*), SUM(IF(size = 0.00 AND size_name = 'B', 1, 0))
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}';
")

success_count=$((total_count - error_count))
success_rate=$(awk "BEGIN {printf \"%.1f\", (${success_count}/${total_count})*100}")
error_rate=$(awk "BEGIN {printf \"%.1f\", (${error_count}/${total_count})*100}")

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

# === DONUT CHART ===
DONUT_CHART_URL="https://quickchart.io/chart?c=$(jq -sRr @uri <<EOF
{
  "type": "doughnut",
  "data": {
    "labels": ["Success (${success_rate}%)", "Failure (${error_rate}%)"],
    "datasets": [{
      "data": [${success_count}, ${error_count}],
      "backgroundColor": ["#4B286D", "#00B7C3"]
    }]
  },
  "options": {
    "plugins": {
      "title": {
        "display": true,
        "text": "Backup Status Overview"
      },
      "legend": {
        "position": "bottom"
      }
    }
  }
}
EOF
)"

# === BAR CHART: Storage per DB Engine ===
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

labels=""
values=""
colors=""
engine_summary_table=""
while IFS=$'\t' read -r engine total; do
    labels="${labels}\"${engine}\","
    values="${values}${total},"
    case "$engine" in
        MYSQL) colors="${colors}\"#00B7C3\"," ;;   # Teal
        PGSQL) colors="${colors}\"#4B286D\"," ;;   # Purple
        MSSQL) colors="${colors}\"#8E44AD\"," ;;   # Deep Purple
        *) colors="${colors}\"#CCCCCC\"," ;;
    esac
    engine_summary_table+="<tr><td>${engine}</td><td>${total} GB</td></tr>"
done <<< "${engine_storage}"

labels="[${labels%,}]"
values="[${values%,}]"
colors="[${colors%,}]"

STACKED_CHART_URL="https://quickchart.io/chart?c=$(jq -sRr @uri <<< "
{
  \"type\": \"bar\",
  \"data\": {
    \"labels\": ${labels},
    \"datasets\": [{
      \"label\": \"GB\",
      \"data\": ${values},
      \"backgroundColor\": ${colors}
    }]
  },
  \"options\": {
    \"plugins\": {
      \"title\": {
        \"display\": true,
        \"text\": \"Daily Storage Utilization (GB)\"
      },
      \"legend\": {
        \"display\": false
      }
    }
  }
}
")"

# === TOP 5 AGGREGATED BACKUPS (Normalized to MB) ===
top_backups=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -e "
SELECT Server, DB_engine, CONCAT(ROUND(SUM(
  CASE size_name
    WHEN 'B' THEN size / 1024 / 1024
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
    WHEN 'B' THEN size / 1024 / 1024
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
body { font-family: 'Helvetica Neue', Arial, sans-serif; background-color: #f4f4f4; color: #333; padding: 20px; }
.container { max-width: 800px; margin: auto; background-color: #fff; padding: 20px; border-radius: 10px; }
h1, h2 { color: #4B286D; text-align: center; }
table { width: 100%; border-collapse: collapse; margin-top: 20px; }
th, td { padding: 10px; border: 1px solid #ddd; text-align: left; }
tr:nth-child(even) { background-color: #f9f9f9; }
</style></head><body><div class='container'>"

echo "<h1>Daily Backup Report - ${REPORT_DATE}</h1>"
echo "<div style='padding: 15px; background-color: #f7f3fb; border-left: 5px solid #4B286D; margin-bottom: 20px;'>"
echo "<p><strong>Executive Summary:</strong><br>"
echo "<span style='color: #008000;'>Status: HIGH SUCCESS (${success_rate}%)</span> | Total Failures: ${error_count} | Total Storage: ${total_storage} GB</p>"
echo "</div>"

echo "<table><tr><td style='width: 50%; text-align: center;'><img src='${DONUT_CHART_URL}' style='max-width: 100%;'></td>"
echo "<td style='width: 50%; text-align: center;'><img src='${STACKED_CHART_URL}' style='max-width: 100%;'></td></tr></table>"

echo "<h2>Storage Summary by Database Type</h2><table><tr><th>Database Engine</th><th>Total Size (GB)</th></tr>"
echo "${engine_summary_table}"
echo "</table>"

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
