#!/bin/bash
tag=0
offset=-99999.99
velocity=0.0
json_data=""

while true; do
    ((tag++))
    if ((tag > 9999999999)); then
        tag=0
    fi

    offset=$(echo "$offset + 0.01" | bc)
    if (( $(echo "$offset > 99999.99" | bc -l) )); then
        offset=-99999.99
    fi

    velocity=$(echo "$velocity + 0.001" | bc)
    if (( $(echo "$velocity > 9.999" | bc -l) )); then
        velocity=0.0
    fi

    #printf "tag=%d, offset=%.2f, velocity=%.3f\n" "$tag" "$offset" "$velocity"
    #redis-cli set OPS:recent_data '{ "tag": "$(tag)", "offset": $offset, "velocity": $velocity }'
    #redis-cli set OPS:recent_data '{ "tag": "$tag", "offset": 123.92, "velocity": 4.987 }'
    json_data=$(printf '{ "tag": "%s", "offset": %.2f, "velocity": %.3f }' "$tag" "$offset" "$velocity")
    redis-cli set OPS:recent_data "$json_data" 1> /dev/null
    #echo "Saved to Redis: $json_data"

    sleep 0.5
done

