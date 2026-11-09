TOKEN=sk-oai-...
ENDPOINT=https://maas.apps....com # Ensure you don't have a trailing '/'
MODEL="publishers/.../models/..."

curl -sk -X POST "${ENDPOINT}/v1/chat/completions" \
	-H "Content-Type: application/json" \
	-H "Authorization: Bearer ${TOKEN}" \
	--data "{
		\"model\": \"${MODEL}\",
		\"messages\": [
			{
				\"role\": \"user\",
				\"content\": \"Give me a 1 sentence summary about bouldering.\"
			}
		]
	}" | jq .

