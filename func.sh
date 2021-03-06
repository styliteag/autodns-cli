#
# lib for InternetX / AutoDNS
#

function _log() {
    local msg=$1
    logger -t "$prog" -i "${prog}: ${msg}"
    #if [[ "DEBUGSYSLOG" = "true" ]] ;then logger -t "$prog" -i "${prog}: ${msg}";fi 
    #if [[ "DEBUGSTDERR" = "true" ]] ;then echo "$msg" >&2 ;fi 
    #echo "$msg" >&2 
 }

# autodns calls
# @test `test_build_call`
# @private
function _build_call() {
	declare -a curl
    local method=$1

    curl+=(curl)
#    if [ -n "$WITH_CHARLES" ]; then
#        curl+=(--proxy 127.0.0.1:8888 -k)
#    fi
    curl+=(--silent)
    curl+=(--show-error)
    curl+=(--user-agent "$prog")
    curl+=(-H "X-Domainrobot-Context:${AUTODNS_CONTEXT}")
	curl+=(-X "$method")
    curl+=(-H 'Accept:application/json')
    if [[ "$method" =~ ^(PUT|POST)$ ]]; then
        curl+=(-H 'Content-Type:application/json')
    fi

	curl+=(-u "${AUTODNS_USER}:${AUTODNS_PASSWORD}")
	curl+=("$endpoint")

	echo "${curl[@]}"
}

# make request and return response
# @TODO integration test
# @private
function _make_request() {
    local cmd="$1"
    local body
    local response

    body=

    if [ $# -gt 1 ]; then
        if [ -n "$2" ]; then
            body="$2"
        fi
    fi

    _log "_make_request: $cmd"
    #_log "_make_request: $body"

    if [ -n "$body" ]; then
        #_log "With body!"
        response=$($cmd -d "$body")
    else
        response=$($cmd)
    fi

    _log "Curl said: $? -> $response"
    if [ $? -ne 0 ]; then
        _log "Error in curl request!"
        return 1
    fi
 
    _validate_response "$response"
    if [ $? -ne 0 ]; then
        #echo "error"
        return 1
    fi

    #_log "Validate response: $error ($?) - $response"

    echo "$response"
}

# checks if we encountered an error
# @TODO write unit test
# @private
function _validate_response() {
    local resp=$1

    _log "_validate_response: $resp"

    echo "$resp"|jq -c -r .  >/dev/null
    if [ $? -ne 0 ]; then
        _log "Invalid or broken JSON: $resp"
        return 1
    fi

    local status=$(echo "$resp"|jq -c -r .status.type)
    if [ -z "${status}" ]; then
        echo "Status not set, something went really wrong!"
        return 1
    fi

    if [ "$status" != "SUCCESS" ]; then
        local message=$(echo "$resp"|jq -r -c '.messages[0].text')
        local code=$(echo "$resp"|jq -r -c '.messages[0].messageCode')

        printf "Request error:\n  Status: %s\n  Message: %s (Code: %s)\n" "$status" "$message" "$code"

        return 1
    fi

    _log "Valid response!"

    return 0
}

# check if a zone has any records so far
# @test `test_has_records`
# @private
function _has_records() {
    local zone=$1
    local count=0
    
    count=$(echo "$zone"|jq '.resourceRecords|length')
    if [[ $count -gt 0 ]]; then
      return 0
    fi

    return 1
}

# @TODO refactor with _has_records?
# @test `test_get_records`
# @private
function _get_records(){
    local zone=$1
    local records

    records="$(echo "$zone"|jq -c -r '.resourceRecords')"
    echo "$records"
}

# replaces IP on an existing record
# @test `test_update_record`
# @private
function _update_record(){
    local data=$1
    local a_record=$2
    local ip=$3

    local records=$(echo "$data"|jq --arg a_record "$a_record" --arg ip "$ip" '.resourceRecords|map(if .name == $a_record then . + {"value": $ip} else . end)')
    tmp=$(mktemp)
    data=$(echo "$data"| jq -c --argjson records "$records" '.resourceRecords = $records' > "$tmp" && cat "$tmp" && rm "$tmp")

    echo "$data"
}

# strips zone-name from it and removes trailing '.' in case
# @test `test_create_record`
# @private
function _create_record() {
    local record
    local domain=$1
    record=${domain/$MY_ZONE/""}

    if [[ "$record" =~ '.'$ ]]; then 
        record=${record%?} # strip trailing dot
    fi
 
    echo "$record"
}

# creates json object for an A-record
# @test `test_create_object`
# @private
function _create_object() {
    local record=$1
    local record_ip=$2
    local record_ttl=$3

    printf '{ "name": "%s", "ttl": %d, "type": "A", "value": "%s" }' "$record" "$record_ttl" "$record_ip"
}

# Adds a record (JSON object) to a zone (JSON object)
# @test `test_add_record_to_zone`
# @private
function _add_record_to_zone(){
    local data=$1
    local record=$2

    local updated_data=$(echo "$data" | jq -c --argjson record "$record" '.resourceRecords += [$record]')

    echo "$updated_data"
}

# parses origin from a result set
# @test `test_get_origin`
# @private
function _get_origin(){
    local zone=$1
    echo "$(echo "$zone" | jq -r '.origin')"
}

#set -x

# @private
# @uses $MY_ZONE
function _build_filter() {
    local operator='EQUAL'
    printf '{"filters": [{"key": "name", "operator": "%s", "value": "%s"}] }' "$operator" "$MY_ZONE"
}

# check if the zone exists
# @TODO Write integration test
# @private
function _zone_exists() {
    local call=$(_build_call "POST")
    local zone_name=$1
    local origin
    local ns

    _log "_zone_exists"
    _log "zone_name: ${zone_name}"

    local request="$call/zone/_search"
    local filter=$(_build_filter)

    _log "Filter: $filter"

    local zones=$(_make_request "$request" "$filter"||echo "ERROR")
    if [[ "$zones" =~ "ERROR" ]]; then
        echo "$zones"
        return 1
    fi

    _log "fetch zones: $zones"

    ns=$(echo "$zones" | jq -r '.data[0].virtualNameServer')
    origin=$(echo "$zones"|jq -r '.data[0].origin')

    if [ "$zone_name" != "$origin" ]; then
        _log "Zone does not exists on Account '$zone_name' != '$origin'"
        return 1
    fi

    echo "$origin/$ns"
}

# return the zone from the API
# @TODO integration test
# @private
function _get_zone() {
    local my_zone="$1"

    local call=$(_build_call "GET")

    local data=$(_make_request "$call/zone/$my_zone")
    _validate_response "$data"
    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "$(echo "$data"|jq -r '.data[0]')"
}

# return only required payload:
# - origin
# - resourceRecords
# @test `test_zone_to_request_payload`
# @private
function _zone_to_request_payload(){
    local zone=$1
    local resp

    origin=$(echo "$zone"|jq -c '.origin')
    records=$(echo "$zone"|jq -c '.resourceRecords')

    printf "{ \"origin\":%s, \"resourceRecords\":%s }" "$origin" "$records"
}

# delete the record by it's name value
#
# @private
function _delete_record(){
    local zone=$1
    local record_name=$2

    local tmp=$(mktemp)
    echo "$(echo "$zone"|jq -r -c --arg record_name "$record_name" 'del(.resourceRecords[]|select(.name==$record_name))' > "$tmp" && cat "$tmp" && rm "$tmp")"
}

# updates the zone object with the given record
# @test `test_update_zone`
# @private
function _update_zone(){
    local zone=$1
    local record=$2

    # try to delete existing record
    # then add record to it

    local name="$(echo "$record"|jq -r '.name')"
    _log "Extracted name: $name (from: $record)"

    local data

    if _has_records "$zone" -eq 0; then
        _log "We have records already, let's delete: .name==$name"

        data=$(_delete_record "$zone" "$name")
    else
        data="$zone"
    fi

    _log "Zone: $data"

    echo "$(_add_record_to_zone "$data" "$record")"
}

#commands
sub_delete() {
    local domain=$1

    if [ -z "$domain" ]; then
        echo "Please provide a domain."
        exit 1
    fi

    if [ -z ${MY_ZONE+x} ]; then
        echo "Missing \$MY_ZONE"
        exit 1
    fi

    local request_uri=$(_zone_exists "$MY_ZONE"||echo "ERROR")
    if [[ "$request_uri" =~ "ERROR" ]]; then
        printf "Zone does not exist (my_zone: %s, Request URI: %s)" "$MY_ZONE" "$request_uri"
        exit 1
    fi

    local data=$(_get_zone "$request_uri"||echo "ERROR")
    if [[ "$data" =~ "ERROR" ]]; then
        printf "Could not retrieve zone: %s" "$data"
        exit 1
    fi

    local a_record=$(_create_record "$domain" "$ip")
    _log "New record: $a_record"

    local payload=$(_delete_record "$data" "$a_record")

    local update_call=$(_build_call "PUT")
    local request_call="$update_call/zone/$request_uri"
    _log "Update call: $request_call"

    local update_request=$(_make_request "$request_call" "$payload"||echo "ERROR")
    if [[ "$update_request" =~ "ERROR" ]]; then
        printf "Update failed: %s" "$update_request"
        exit 1
    fi

    _log "API response (PUT/update): $update_request (Code: $?)"

    echo "Success!"
    exit 0
}
sub_help() {
	echo ""
    cat $( cd "$( dirname $(readlink -f ${BASH_SOURCE[0]}) )" >/dev/null 2>&1 && pwd )/README.md
    echo ""
}

# show current zone "info"
sub_show() {
    local request_uri=$(_zone_exists "$MY_ZONE"||echo "ERROR")
    if [[ "$request_uri" =~ "ERROR" ]]; then
        echo "$request_uri"
        exit 1
    fi

    local data=$(_get_zone "$request_uri"||echo "ERROR")
    if [[ "$data" =~ "ERROR" ]]; then
        echo "$data"
        exit 1
    fi

    echo "$(echo "$data"|jq -C '.')"
}

# add/update a record in the zone
sub_update() {
    local domain=$1
    local ip=$2

    if [ -z "$domain" ]; then
        echo "Please provide a domain."
        return 1
    fi

    if [ -z "$ip" ]; then
        echo "Please provide an IP."
        return 1
    fi

    if [ -z ${MY_ZONE+x} ]; then
        echo "Missing \$MY_ZONE"
        return 1
    fi

    local request_uri=$(_zone_exists "$MY_ZONE"||echo "ERROR")
    if [[  "$request_uri" =~ "ERROR" ]]; then
        printf "Zone does not exist (my_zone: %s) %s" "$MY_ZONE" "$request_uri"
        return 1
    fi

    local data=$(_get_zone "$request_uri"||echo "ERROR")
    if [[ "$data" =~ "ERROR"  ]‚]; then
        printf "Could not retrieve zone: %s" "$data"
        return 1
    fi
    #exit 99

    _log "Zone data: $data"

    local a_record=$(_create_record "$domain" "$ip")
    _log "New record: $a_record"

    local obj=$(_create_object "$a_record" "$ip" "$ttl")
    _log "Created object: $obj"

    local payload=$(_update_zone "$data" "$obj")
    
    local update_call=$(_build_call "PUT")
    local request_call="$update_call/zone/$request_uri"
    _log "Update call: $request_call"

    local update_request=$(_make_request "$request_call" "$payload"||echo "ERROR")
    if [[ "$update_request" =~ "ERROR" ]]; then
        printf "Update failed: %s" "$update_request"
        return 1
    fi
   
    _log "API response (PUT/update): $update_request"

    echo "Success!"
    exit 0
}