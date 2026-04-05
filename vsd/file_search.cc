#include "file_search.h"

#include <iostream>
#include <cstdio>
#include <stdio.h>
#include <map>
#include <iterator>
#include <string>
#include <fstream>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <strings.h>
#include <memory.h>

CSearchFile::CSearchFile()
{
}

CSearchFile::~CSearchFile()
{
}

bool CSearchFile::GetFileList(FILE_LIST& list, std::string strDir)
{
    struct stat statinfo;
    memset(&statinfo, 0, sizeof(statinfo));
    lstat(strDir.c_str(), &statinfo);
    if(!S_ISDIR(statinfo.st_mode))
    {
        std::cout<<strDir + " is not directory"<<std::endl;
        return false;
    }

    DIR *dir;
    struct dirent *entry;

    if ((dir = opendir(strDir.c_str())) == NULL)
    {
        std::cout<<strDir + " open error"<<std::endl;
        return false;
    }

    while ((entry = readdir(dir)) != NULL)
    {
        memset(&statinfo, 0, sizeof(statinfo));
        std::string strFilePath = strDir + "/" + entry->d_name;
        while(strFilePath.find("//") != std::string::npos)
                strFilePath.replace(strFilePath.find("//"), 2, "/");

        lstat(strFilePath.c_str(), &statinfo);

        if(S_ISDIR(statinfo.st_mode))
        {
            if(strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
                continue;
            list.insert(std::pair<std::string, bool>(strFilePath, true));
        }
        else
        {
            list.insert(std::pair<std::string, bool>(strFilePath, false));
        }
    }

     closedir(dir);

    return true;
}

void CSearchFile::ShowFileList(FILE_LIST& list)
{
    FILE_LIST::iterator itr;
    for(itr = list.begin(); itr != list.end(); itr++)
    {
        if(itr->second == true)
            std::cout<<"[DIRECTORY] " + itr->first<<std::endl;
        else
            std::cout<<"[FILE]" + itr->first<<std::endl;
    }
}

bool CSearchFile::CheckFileName(std::string fname, std::string strDir, std::string prefix, std::string postfix) {
    const char *ch = fname.c_str();
    
    if(strncmp(ch, strDir.c_str(), strDir.length()) != 0) return false;
    ch+= strDir.length();
    if(*ch != '/') return false;
    ch++;
    if(strncmp(ch, prefix.c_str(), prefix.length()) != 0) return false;
    ch+= prefix.length();
    if(strlen(ch) < postfix.length()) return false;
    ch+= strlen(ch) - postfix.length();
    if(strncmp(ch, postfix.c_str(), postfix.length()) != 0) return false;

    return true;
}

bool CSearchFile::SearchFileName(std::string& fname, std::string strDir, std::string prefix, std::string postfix) {
    FILE_LIST file_list;
    int file_cnt = 0;
    std::string strTemp = "";
    
    GetFileList(file_list, strDir);
    FILE_LIST::iterator itr;
    for(itr = file_list.begin(); itr != file_list.end(); itr++)
    {
        if(itr->second == false) {
            if(CheckFileName(itr->first, strDir, prefix, postfix) == true) {
                strTemp = itr->first;
                file_cnt++;
            }
        }
    }

    if(file_cnt == 1) {
        fname = strTemp;
        return true;
    }

    return false;
}


int CSearchFile::SearchFileList(FILE_LIST& list, std::string strDir, std::string prefix, std::string postfix) {
    FILE_LIST file_list;
    int file_cnt = 0;
    std::string strTemp = "";
    
    GetFileList(file_list, strDir);
    FILE_LIST::iterator itr;
    for(itr = file_list.begin(); itr != file_list.end(); itr++)
    {
        if(itr->second == false) {
            if(CheckFileName(itr->first, strDir, prefix, postfix) == true) {
                list.insert(std::pair<std::string, bool>(itr->first, false));
                file_cnt++;
            }
        }
    }

    return file_cnt;
}

void CSearchFile::RemoveFileList(FILE_LIST& list) {
    FILE_LIST::iterator itr;
    for(itr = list.begin(); itr != list.end(); itr++)
    {
        if(itr->second == false) remove(itr->first.c_str());
    }
    list.clear();
}