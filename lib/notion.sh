#!/usr/bin/env bash
# Notion REST API helpers

NOTION_API_BASE="https://api.notion.com/v1"
NOTION_VERSION="2022-06-28"
NOTION_DB_ID="30beadd9-aef9-81d8-aac4-000bcc2f947d"

notion_headers() {
  echo -H "Authorization: Bearer $NOTION_API_KEY" \
       -H "Notion-Version: $NOTION_VERSION" \
       -H "Content-Type: application/json"
}

notion_get() {
  local url="$1"
  curl -s "$url" \
    -H "Authorization: Bearer $NOTION_API_KEY" \
    -H "Notion-Version: $NOTION_VERSION"
}

notion_post() {
  local url="$1"
  local data="$2"
  curl -s "$url" \
    -H "Authorization: Bearer $NOTION_API_KEY" \
    -H "Notion-Version: $NOTION_VERSION" \
    -H "Content-Type: application/json" \
    -d "$data"
}

notion_patch() {
  local url="$1"
  local data="$2"
  curl -s -X PATCH "$url" \
    -H "Authorization: Bearer $NOTION_API_KEY" \
    -H "Notion-Version: $NOTION_VERSION" \
    -H "Content-Type: application/json" \
    -d "$data"
}

# Extract page ID from a Notion URL
notion_extract_page_id() {
  local url="$1"
  # Handle URLs like https://www.notion.so/Title-abc123def456 or raw IDs
  local raw
  raw=$(echo "$url" | grep -oE '[0-9a-f]{32}' | tail -1)
  if [[ -z "$raw" ]]; then
    raw=$(echo "$url" | grep -oE '[0-9a-f-]{36}' | tail -1)
    echo "$raw"
  else
    # Insert hyphens: 8-4-4-4-12
    echo "${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
  fi
}

# Query open tasks from the database
notion_query_open_tasks() {
  local response
  response=$(notion_post "$NOTION_API_BASE/databases/$NOTION_DB_ID/query" '{
    "filter": {
      "or": [
        {"property": "Status", "select": {"equals": "Ready for Dev"}},
        {"property": "Status", "select": {"equals": "To Do"}},
        {"property": "Status", "select": {"equals": "Captured"}}
      ]
    },
    "sorts": [{"property": "Priority", "direction": "descending"}],
    "page_size": 20
  }')
  echo "$response"
}

# Get page properties
notion_get_page() {
  local page_id="$1"
  notion_get "$NOTION_API_BASE/pages/$page_id"
}

# Get page blocks (body content)
notion_get_blocks() {
  local page_id="$1"
  notion_get "$NOTION_API_BASE/blocks/$page_id/children?page_size=100"
}

# Get page comments
notion_get_comments() {
  local page_id="$1"
  notion_get "$NOTION_API_BASE/comments?block_id=$page_id"
}

# Update task status
notion_update_status() {
  local page_id="$1"
  local status="$2"
  notion_patch "$NOTION_API_BASE/pages/$page_id" \
    "{\"properties\": {\"Status\": {\"select\": {\"name\": \"$status\"}}}}"
}

# Create a new task
notion_create_task() {
  local title="$1"
  notion_post "$NOTION_API_BASE/pages" "{
    \"parent\": {\"database_id\": \"$NOTION_DB_ID\"},
    \"properties\": {
      \"Task\": {\"title\": [{\"text\": {\"content\": \"$title\"}}]},
      \"Status\": {\"select\": {\"name\": \"In Progress\"}}
    }
  }"
}

# Extract title from page response
notion_extract_title() {
  local page_json="$1"
  echo "$page_json" | jq -r '.properties.Task.title[0].text.content // .properties.Name.title[0].text.content // "Untitled"'
}

# Extract description from page response
notion_extract_description() {
  local page_json="$1"
  echo "$page_json" | jq -r '.properties.Description.rich_text[0].text.content // ""'
}

# Extract status from page response
notion_extract_status() {
  local page_json="$1"
  echo "$page_json" | jq -r '.properties.Status.select.name // "Unknown"'
}

# Convert blocks to markdown (simplified)
notion_blocks_to_markdown() {
  local blocks_json="$1"
  echo "$blocks_json" | jq -r '
    .results[] |
    if .type == "paragraph" then
      (.paragraph.rich_text | map(.plain_text) | join("")) + "\n"
    elif .type == "heading_1" then
      "# " + (.heading_1.rich_text | map(.plain_text) | join(""))
    elif .type == "heading_2" then
      "## " + (.heading_2.rich_text | map(.plain_text) | join(""))
    elif .type == "heading_3" then
      "### " + (.heading_3.rich_text | map(.plain_text) | join(""))
    elif .type == "bulleted_list_item" then
      "- " + (.bulleted_list_item.rich_text | map(.plain_text) | join(""))
    elif .type == "numbered_list_item" then
      "1. " + (.numbered_list_item.rich_text | map(.plain_text) | join(""))
    elif .type == "to_do" then
      (if .to_do.checked then "- [x] " else "- [ ] " end) + (.to_do.rich_text | map(.plain_text) | join(""))
    elif .type == "code" then
      "```" + (.code.language // "") + "\n" + (.code.rich_text | map(.plain_text) | join("")) + "\n```"
    elif .type == "quote" then
      "> " + (.quote.rich_text | map(.plain_text) | join(""))
    elif .type == "divider" then
      "---"
    elif .type == "callout" then
      "> " + (.callout.icon.emoji // "💡") + " " + (.callout.rich_text | map(.plain_text) | join(""))
    else
      ""
    end
  ' 2>/dev/null
}

# Convert comments to markdown
notion_comments_to_markdown() {
  local comments_json="$1"
  echo "$comments_json" | jq -r '
    .results | sort_by(.created_time) | .[] |
    "**" + .created_time[0:16] + "** — " + (.rich_text | map(.plain_text) | join(""))
  ' 2>/dev/null
}

# Display tasks for interactive selection
notion_display_tasks() {
  local tasks_json="$1"
  local count
  count=$(echo "$tasks_json" | jq '.results | length')

  if [[ "$count" == "0" ]]; then
    warn "No open tasks found in Notion."
    return 1
  fi

  header "Open Tasks"
  echo "$tasks_json" | jq -r '
    .results | to_entries[] |
    "  \(.key + 1)) [\(.value.properties.Priority.select.name // "—")] \(.value.properties.Task.title[0].text.content // "Untitled")"
  '
  echo ""
  echo -en "${YELLOW}Pick a task (1-${count}): ${NC}"
  read -r pick

  if [[ "$pick" -ge 1 && "$pick" -le "$count" ]]; then
    local idx=$((pick - 1))
    echo "$tasks_json" | jq -r ".results[$idx].id"
  else
    error "Invalid selection."
    return 1
  fi
}
