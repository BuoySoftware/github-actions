#!/bin/bash

# Test the ticket extraction logic
IFS=',' read -ra PATTERNS <<< "DXD-[0-9]+,DX-[0-9]+"

ticket_id=""
for pattern in "${PATTERNS[@]}"; do
  # Trim whitespace from pattern
  pattern=$(echo "$pattern" | xargs)
  if [ -n "$pattern" ]; then
    extracted=$(echo "wm/DX-415-localize-date-time-for-daily-missed-appointments-job" | grep -oiE "$pattern")
    if [ -n "$extracted" ]; then
      ticket_id="$extracted"
      break
    fi
  fi
done

echo "ticket_id=$ticket_id"

if [ -n "$ticket_id" ]; then
  jira_url="https://buoysoftware.atlassian.net/browse/${ticket_id}"
  echo "jira_url=$jira_url"
else
  echo "No ticket ID found"
fi 