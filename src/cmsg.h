#pragma once

#include <stddef.h>

size_t getCmsgSpace(size_t data_len);
void makeFdTransferCmsg(char* buf, char const* data, size_t data_len);
