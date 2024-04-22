#!/bin/bash
_true="true"
_false="false"
_result=$_false
_u_dir=""

fn_create_md5_list(){
	local dir=$1
	if [ -z "$dir" -o "$dir" == " " -o "$dir" == "" ]; then
		_result=$_false
	elif [ ! -d "$dir" ]; then
		_result=$_false
	else
		if [ -e "$dir/md5.list" ]; then
			rm "$dir/md5.list"
		fi
		
		cd $dir
		find . -type f -exec md5sum {} \; > /tmp/md5.list 2> /dev/null
		mv /tmp/md5.list "$dir"
		_result=$_true
	fi
}

fn_check_md5_list() {
	local dir=$1
	local str=""
	if [ -z "$dir" -o "$dir" == " " -o "$dir" == "" ]; then
		_result=$_false
	elif [ ! -d "$dir" ]; then
		_result=$_false
	else
		if [ ! -f "$dir/md5.list" ]; then
			_result=$_false
		else
			cd "$dir"
			str=`md5sum --quiet -c "$dir/md5.list" 2> /dev/null`
			if [ -z "$str" -o "$str" == " " -o "$str" == "" ]; then
				_result=$_true
			else
				_result=$_false
			fi
		fi
	fi
}

fn_create_zip() {
	local dir=$(realpath "$1")
	if [ -z "$dir" -o "$dir" == " " -o "$dir" == "" ]; then
		_result=$_false
	elif [ ! -d "$dir" ]; then
		_result=$_false
	else
		local c_dir=""
		local f_name=""
		
		c_dir=$(realpath "$dir/../")
		f_name=$(basename $(realpath "$dir"))
		if [ ! -d "$c_dir" ]; then
			_result=$_false
		elif [ -z "$f_name" -o "$f_name" == " " -o "$f_name" == "" ]; then
			_result=$_false
		else
			local zip_path="$c_dir/$f_name.zip"
			cd "$dir"
			zip -r "$zip_path" . > /dev/null
			if [ ! -e "$zip_path" ]; then
				_result=$_false
			else
				chmod u+rwx "$zip_path"
				_result=$_true
			fi
		fi
	fi
}

fn_untie_zip() {
	local zip_path=$1
	if [ -z "$zip_path" -o "$zip_path" == " " -o "$zip_path" == "" ]; then
		_result=$_false
	elif [ ! -e "$zip_path" ]; then
		_result=$_false
	else
		local f_name=$(basename "$zip_path")
		local f_extension="${f_name##*.}"
		_u_dir="/tmp/upgrade"
		
		if [ $f_extension != "zip" ]; then
			_result=$_false
		else
			rm -rf "$_u_dir"
			mkdir -p "$_u_dir"
			unzip "$zip_path" -d "$_u_dir" > /dev/null 2>/dev/null
			_result=$_true
		fi
	fi
}

case $1 in
	create)
		fn_create_md5_list $2
		if [ "$_result" == "$_true" ]; then
			fn_create_zip $2
			if [ "$_result" == "$_true" ]; then
				exit 0
			else
				exit 1
			fi
		else
			exit 1
		fi
		;;
	check)
		if [ -d $2 ]; then
			_u_dir=$2
		else
			fn_untie_zip $2
			if [ "$_result" != "$_true" ]; then
				exit 1
			fi
		fi
		
		fn_check_md5_list $_u_dir
		if [ "$_result" == "$_true" ]; then
			exit 0
		else
			exit 1
		fi
		;;
	*) exit 1;;
esac
