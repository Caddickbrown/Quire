#pragma once
// A small JSON reader for host tests only (the firmware itself reads flat replies with
// homecore::jsonField). Header-only, so nothing here is compiled into a firmware build.
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <vector>

namespace homecore_test {

struct Json {
  enum Kind { Null, Bool, Number, String, Array, Object } kind = Null;
  bool b = false;
  double num = 0;
  std::string text;      // a string's value; a number's literal text
  std::vector<Json> items;
  std::vector<std::pair<std::string, Json>> fields;   // in file order

  bool isNull() const { return kind == Null; }
  const Json& operator[](const char* key) const {
    static const Json none;
    for (const auto& f : fields) if (f.first == key) return f.second;
    return none;
  }
  bool has(const char* key) const {
    for (const auto& f : fields) if (f.first == key) return true;
    return false;
  }
  const std::string& str() const { return text; }
  long long i64() const { return strtoll(text.c_str(), nullptr, 10); }

  // Compact JSON again (strings escaped), so a test can hand a manifest to the firmware's reader.
  std::string dump() const {
    switch (kind) {
      case Null: return "null";
      case Bool: return b ? "true" : "false";
      case Number: return text;
      case String: return quote(text);
      case Array: {
        std::string s = "[";
        for (size_t i = 0; i < items.size(); i++) s += (i ? "," : "") + items[i].dump();
        return s + "]";
      }
      case Object: {
        std::string s = "{";
        for (size_t i = 0; i < fields.size(); i++)
          s += (i ? "," : "") + quote(fields[i].first) + ":" + fields[i].second.dump();
        return s + "}";
      }
    }
    return "null";
  }

  static std::string quote(const std::string& v) {
    std::string s = "\"";
    for (unsigned char c : v) {
      if (c == '"') s += "\\\"";
      else if (c == '\\') s += "\\\\";
      else if (c == '\n') s += "\\n";
      else if (c == '\r') s += "\\r";
      else if (c == '\t') s += "\\t";
      else if (c < 0x20) { char u[8]; snprintf(u, sizeof(u), "\\u%04x", c); s += u; }
      else s += (char)c;
    }
    return s + "\"";
  }
};

class JsonReader {
 public:
  explicit JsonReader(const std::string& s) : s_(s) {}
  bool read(Json& out) {
    if (!value(out)) return false;
    ws();
    return i_ == s_.size();
  }

 private:
  const std::string& s_;
  size_t i_ = 0;

  void ws() { while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\r' || s_[i_] == '\n')) i_++; }
  bool lit(const char* w) {
    size_t n = strlen_(w);
    if (s_.compare(i_, n, w) != 0) return false;
    i_ += n;
    return true;
  }
  static size_t strlen_(const char* w) { size_t n = 0; while (w[n]) n++; return n; }
  static void utf8(std::string& o, unsigned long cp) {
    if (cp < 0x80) o += (char)cp;
    else if (cp < 0x800) { o += (char)(0xC0 | (cp >> 6)); o += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { o += (char)(0xE0 | (cp >> 12)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F)); }
    else { o += (char)(0xF0 | (cp >> 18)); o += (char)(0x80 | ((cp >> 12) & 0x3F)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F)); }
  }
  bool hex4(unsigned long& cp) {
    if (i_ + 4 > s_.size()) return false;
    std::string h = s_.substr(i_, 4);
    char* end = nullptr;
    cp = strtoul(h.c_str(), &end, 16);
    if (end != h.c_str() + 4) return false;
    i_ += 4;
    return true;
  }
  bool string(std::string& o) {
    if (s_[i_] != '"') return false;
    i_++;
    while (i_ < s_.size()) {
      char c = s_[i_++];
      if (c == '"') return true;
      if (c != '\\') { o += c; continue; }
      if (i_ >= s_.size()) return false;
      char e = s_[i_++];
      switch (e) {
        case '"': o += '"'; break;
        case '\\': o += '\\'; break;
        case '/': o += '/'; break;
        case 'b': o += '\b'; break;
        case 'f': o += '\f'; break;
        case 'n': o += '\n'; break;
        case 'r': o += '\r'; break;
        case 't': o += '\t'; break;
        case 'u': {
          unsigned long cp;
          if (!hex4(cp)) return false;
          if (cp >= 0xD800 && cp < 0xDC00) {
            unsigned long lo;
            if (!lit("\\u") || !hex4(lo)) return false;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          }
          utf8(o, cp);
          break;
        }
        default: return false;
      }
    }
    return false;
  }
  bool value(Json& out) {
    ws();
    if (i_ >= s_.size()) return false;
    char c = s_[i_];
    if (c == '{') {
      out.kind = Json::Object;
      i_++;
      ws();
      if (i_ < s_.size() && s_[i_] == '}') { i_++; return true; }
      while (true) {
        ws();
        std::string k;
        if (i_ >= s_.size() || !string(k)) return false;
        ws();
        if (i_ >= s_.size() || s_[i_] != ':') return false;
        i_++;
        Json v;
        if (!value(v)) return false;
        out.fields.emplace_back(k, std::move(v));
        ws();
        if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
        if (i_ < s_.size() && s_[i_] == '}') { i_++; return true; }
        return false;
      }
    }
    if (c == '[') {
      out.kind = Json::Array;
      i_++;
      ws();
      if (i_ < s_.size() && s_[i_] == ']') { i_++; return true; }
      while (true) {
        Json v;
        if (!value(v)) return false;
        out.items.push_back(std::move(v));
        ws();
        if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
        if (i_ < s_.size() && s_[i_] == ']') { i_++; return true; }
        return false;
      }
    }
    if (c == '"') { out.kind = Json::String; return string(out.text); }
    if (lit("true")) { out.kind = Json::Bool; out.b = true; return true; }
    if (lit("false")) { out.kind = Json::Bool; out.b = false; return true; }
    if (lit("null")) { out.kind = Json::Null; return true; }
    size_t start = i_;
    while (i_ < s_.size() && (s_[i_] == '-' || s_[i_] == '+' || s_[i_] == '.' || s_[i_] == 'e' || s_[i_] == 'E' ||
                              (s_[i_] >= '0' && s_[i_] <= '9'))) i_++;
    if (i_ == start) return false;
    out.kind = Json::Number;
    out.text = s_.substr(start, i_ - start);
    out.num = strtod(out.text.c_str(), nullptr);
    return true;
  }
};

// Reads a whole file as JSON. False (and a message) when it can't.
inline bool loadJsonFile(const char* path, Json& out) {
  FILE* f = fopen(path, "rb");
  if (!f) { printf("can't open %s\n", path); return false; }
  std::string s;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) s.append(buf, n);
  fclose(f);
  if (!JsonReader(s).read(out)) { printf("%s isn't valid JSON\n", path); return false; }
  return true;
}

}  // namespace homecore_test
