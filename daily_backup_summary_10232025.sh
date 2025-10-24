#!/bin/bash
# === CONFIGURATION ===
DB_USER="trtel.backup"
DB_PASS="Telus2017#"
DB_NAME="ti_db_inventory"
REPORT_DATE=$(date -d "yesterday" '+%Y-%m-%d')
DIR="backup"
mkdir -p "${DIR}"
emailFile="${DIR}/daily_backup_report.html"

# === FETCH DATA FROM DATABASE ===
SUMMARY=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D "${DB_NAME}" -N -e "
  SELECT 
    SUM(CASE WHEN status='SUCCESS' THEN 1 ELSE 0 END),
    SUM(CASE WHEN status='FAILED' THEN 1 ELSE 0 END),
    ROUND(SUM(
      CASE size_name
        WHEN 'B' THEN size/1024/1024/1024
        WHEN 'KB' THEN size/1024/1024
        WHEN 'MB' THEN size/1024
        ELSE size
      END
    ), 2)
  FROM backup_inventory
  WHERE backup_date='${REPORT_DATE}';
")

SUCCESS_COUNT=$(echo "$SUMMARY" | awk '{print $1}')
FAIL_COUNT=$(echo "$SUMMARY" | awk '{print $2}')
TOTAL_SIZE=$(echo "$SUMMARY" | awk '{print $3}')
TOTAL_COUNT=$((SUCCESS_COUNT + FAIL_COUNT))

if [ "$TOTAL_COUNT" -eq 0 ]; then
  PERCENT_SUCCESS=0
else
  PERCENT_SUCCESS=$((SUCCESS_COUNT * 100 / TOTAL_COUNT))
fi

# === DETERMINE STATUS ===
if [ "$PERCENT_SUCCESS" -eq 100 ]; then
  STATUS="HIGH SUCCESS"
  COLOR="green"
elif [ "$PERCENT_SUCCESS" -ge 80 ]; then
  STATUS="PARTIAL SUCCESS"
  COLOR="orange"
else
  STATUS="FAILED"
  COLOR="red"
fi

# === FETCH TOP 5 BACKUPS ===
TOP_BACKUPS=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D "${DB_NAME}" -e "
  SELECT server_name, db_technology, 
  ROUND(CASE size_name
    WHEN 'B' THEN size/1024/1024
    WHEN 'KB' THEN size/1024
    WHEN 'MB' THEN size
    WHEN 'GB' THEN size*1024
    ELSE size
  END, 2) AS size_in_mb
  FROM backup_inventory
  WHERE backup_date='${REPORT_DATE}'
  ORDER BY size_in_mb DESC
  LIMIT 5;
")

# === PREPARE ARRAYS FOR CHART ===
LABELS=()
DATA=()
while IFS=$'\t' read -r SERVER ENGINE SIZE_MB; do
  if [ "$SERVER" != "server_name" ]; then
    LABELS+=("$SERVER")
    DATA+=("$SIZE_MB")
  fi
done < <(echo "$TOP_BACKUPS" | tail -n +2)

# === FIXED JSON CONVERSION ===
LABELS_JSON=$(printf '%s\n' "${LABELS[@]}" | jq -R -s -c 'split("\n") | map(select(length>0))')
DATA_JSON=$(printf '%s\n' "${DATA[@]}" | jq -R -s -c 'split("\n") | map(select(length>0)) | map(tonumber)')

# === GENERATE EMAIL REPORT (RESTORED ORIGINAL DESIGN) ===
cat > "$emailFile" <<EOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Daily Backup Report - ${REPORT_DATE}</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    body { font-family: Arial, sans-serif; background-color: #fdfdfd; color: #333; margin: 0; padding: 0; }
    h2 { color: #4B0082; text-align: center; margin-top: 20px; }
    .summary-box { background: #f4f0fa; border-left: 6px solid #4B0082; margin: 20px auto; width: 90%; padding: 10px 20px; border-radius: 6px; }
    .summary-box b { display: block; }
    .charts { display: flex; justify-content: center; align-items: center; flex-wrap: wrap; }
    canvas { margin: 20px; }
    table { width: 90%; margin: 0 auto; border-collapse: collapse; font-size: 14px; }
    th { background-color: #4B0082; color: white; padding: 8px; text-align: left; }
    td { padding: 8px; border-bottom: 1px solid #ddd; text-align: left; }
    h3 { color: #4B0082; text-align: center; margin-top: 40px; }
  </style>
</head>
<body>
  <h2>Daily Backup Report - ${REPORT_DATE}</h2>

  <div class="summary-box">
    <b>Executive Summary:</b>
    <span style="color:${COLOR};">Status: ${STATUS} (${PERCENT_SUCCESS}%)</span> |
    Total Failures: ${FAIL_COUNT} | Total Storage: ${TOTAL_SIZE} GB
  </div>

  <div class="charts">
    <canvas id="donutChart" width="300" height="300"></canvas>
    <canvas id="barChart" width="600" height="300"></canvas>
  </div>

  <h3>Top 5 Largest Backups</h3>
  <table>
    <tr><th>Server</th><th>Database Engine</th><th>Size</th></tr>
EOF

echo "$TOP_BACKUPS" | tail -n +2 | while IFS=$'\t' read -r SERVER ENGINE SIZE_MB; do
  echo "<tr><td>${SERVER}</td><td>${ENGINE}</td><td>${SIZE_MB} MB</td></tr>" >> "$emailFile"
done

cat >> "$emailFile" <<EOF
  </table>

  <script>
    const donutCtx = document.getElementById('donutChart');
    new Chart(donutCtx, {
      type: 'doughnut',
      data: {
        labels: ['Success (%)', 'Failure (%)'],
        datasets: [{
          data: [${PERCENT_SUCCESS}, ${FAIL_COUNT}],
          backgroundColor: ['#4B0082', '#C0C0C0']
        }]
      },
      options: { responsive: false }
    });

    const barCtx = document.getElementById('barChart');
    new Chart(barCtx, {
      type: 'bar',
      data: {
        labels: ${LABELS_JSON},
        datasets: [{
          label: 'Backup Size (MB)',
          data: ${DATA_JSON},
          backgroundColor: '#4B0082'
        }]
      },
      options: {
        responsive: false,
        scales: { y: { beginAtZero: true } }
      }
    });
  </script>
</body>
</html>
EOF

# === SEND EMAIL ===
mail -a "Content-Type: text/html" -s "Daily Backup Report - ${REPORT_DATE}" yvette.halili@telusinternational.com < "$emailFile"
echo "Email sent to yvette.halili@telusinternational.com"
