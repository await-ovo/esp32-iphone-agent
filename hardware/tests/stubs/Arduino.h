#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>

// Only the Arduino surface used by hid_control.cpp, so its command path runs on the host.
class String : public std::string {
public:
  using std::string::string;
  String(const std::string &s) : std::string(s) {}
  String(uint32_t value) : std::string(std::to_string(value)) {}
  int indexOf(char c) const { auto p = find(c); return p == npos ? -1 : (int)p; }
  String substring(size_t start) const { return substr(start); }
  String substring(size_t start, size_t end) const { return substr(start, end - start); }
};
inline long constrain(long v, long lo, long hi) { return std::clamp(v, lo, hi); }
inline void delay(unsigned) {}
