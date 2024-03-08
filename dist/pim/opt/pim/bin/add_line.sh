#!/bin/bash

new_line=$1
new_line=$(echo "$new_line" | sed 's/[[:space:]]//g')

file_path=$2
temp_file_path="/tmp/tmp_add_line"
# Check if the file exists
if [ ! -f "$file_path" ]; then
    echo "File not found: $file_path"
    exit 1
fi

echo "new_line:'$1', file:$2"

if grep -q "^#[[:space:]]*$1" "$file_path"; then
    sed -i "?^#[[:space:]]*$1? s?^#??" "$file_path"
    echo "Removed '#' in front of '$1' in the file: $file_path"
    exit 0
fi

cp "$file_path" "$temp_file_path"
# Remove lines with comments and strip whitespaces and tabs from the file
#sed -i '/^[[:space:]]*#/d' "$temp_file_path"
sed -i 's?[[:space:]]??g' "$temp_file_path"

#echo "Removed all whitespaces and tabs from the file."

if grep -q "^$new_line" "$temp_file_path"; then
    echo "line exist"
else
    echo "line not exist"
    echo "$1" >> "$file_path"
    echo "add line"
fi

rm "$temp_file_path"


