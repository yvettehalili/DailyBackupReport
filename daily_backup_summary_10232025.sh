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
    MYSQL) COLOR_CODE="#6A4C93" ;;
    PGSQL) COLOR_CODE="#00A6A6" ;;
    MSSQL) COLOR_CODE="#8BC34A" ;;
    ORACLE) COLOR_CODE="#FF7043" ;;
    *) COLOR_CODE="#B0BEC5" ;;
  esac
  COLORS+=("$COLOR_CODE")
done <<< "$(echo "${engine_storage}" | tr -d '\r')"

LABELS_JSON=$(printf '%s\n' "${LABELS[@]}" | jq -Rsc 'split("\n")[:-1]')
DATA_JSON=$(printf '%s\n' "${DATA[@]}" | jq -Rsc 'split("\n")[:-1] | map(tonumber)')
COLORS_JSON=$(printf '%s\n' "${COLORS[@]}" | jq -Rsc 'split("\n")[:-1]')

# === DONUT CHART ===
DONUT_CHART_JSON=$(cat <<EOF
{
  "type": "doughnut",
  "data": {
    "labels": ["Success (${success_rate}%)", "Failure (${error_rate}%)"],
    "datasets": [{
      "data": [${success_count}, ${error_count}],
      "backgroundColor": ["#6A4C93", "#00A6A6"],
      "borderWidth": 2
    }]
  },
  "options": {
    "layout": {
      "padding": { "top": 20, "bottom": 20 }
    },
    "plugins": {
      "title": {
        "display": true,
        "text": "Backup Status Overview",
        "color": "#4B286D",
        "font": { "size": 18, "weight": "bold" },
        "padding": { "bottom": 20 }
      },
      "legend": {
        "position": "bottom",
        "labels": {
          "color": "#4B286D",
          "font": { "weight": "bold" }
        }
      },
      "datalabels": {
        "color": "#ffffff",
        "font": { "size": 16, "weight": "bold" }
      }
    }
  }
}
EOF
)

# === BAR CHART (Fixed Overlap) ===
BAR_CHART_JSON=$(cat <<EOF
{
  "type": "bar",
  "data": {
    "labels": ${LABELS_JSON},
    "datasets": [{
      "label": "Total Storage (GB)",
      "data": ${DATA_JSON},
      "backgroundColor": ${COLORS_JSON},
      "borderRadius": 10
    }]
  },
  "options": {
    "layout": {
      "padding": { "top": 120, "bottom": 40 }
    },
    "plugins": {
      "title": {
        "display": true,
        "text": "Daily Backup Storage by DB Engine",
        "color": "#4B286D",
        "font": { "size": 20, "weight": "bold" },
        "padding": { "bottom": 50 }
      },
      "legend": {
        "display": true,
        "position": "bottom",
        "labels": {
          "color": "#4B286D",
          "font": { "weight": "bold" },
          "padding": 30
        }
      },
      "datalabels": {
        "anchor": "end",
        "align": "top",
        "offset": 10,
        "clip": false,
        "padding": { "top": 12 },
        "color": "#4B286D",
        "font": { "weight": "bold", "size": 14 },
        "formatter": "(value) => value + ' GB'"
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
}
EOF
)

# === CHART URL GENERATION ===
DONUT_CHART_URL=$(post_chart_json "${DONUT_CHART_JSON}" 350 350 white)
BAR_CHART_URL=$(post_chart_json "${BAR_CHART_JSON}" 600 350 white)
