#ifndef __FILE_SEARCH_H__
#define __FILE_SEARCH_H__

#include <map>
#include <string>
#include <sys/types.h>

typedef std::map<std::string, bool> FILE_LIST;

class CSearchFile
{
public:
    CSearchFile();
    ~CSearchFile();

    bool SearchFileName(std::string& fname, std::string strDir, std::string prefix, std::string postfix);
    int  SearchFileList(FILE_LIST& list, std::string strDir, std::string prefix, std::string postfix);
    void RemoveFileList(FILE_LIST& list);
    
    bool GetFileList(FILE_LIST& list, std::string strDir);
    void ShowFileList(FILE_LIST& list);
    bool CheckFileName(std::string fname, std::string strDir, std::string prefix, std::string postfix);
};

#endif