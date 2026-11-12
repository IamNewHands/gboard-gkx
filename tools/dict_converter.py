#!/usr/bin/env python3
"""dict_converter.py — 外部词库转 Gboard iOS (Mozc) user_dictionary.db 转换器。

支持格式:
  1. Rime 万象方案词库 (*.dict.yaml / *.txt):
     格式如: 词条\t拼音\t权重 或 词条\t拼音
  2. 搜狗细胞词库 (*.scel):
     搜狗二进制细胞词库，自动解析 UTF-16LE 拼音表与词条
  3. 标准拼音/短语文本 (*.txt):
     格式如: 拼音<TAB>词条 或 词条<TAB>拼音

输出:
  user_dictionary.db (Mozc Protocol Buffers 二进制格式，纯 Python 序列化，无第三方依赖)
"""

import argparse
import os
import re
import struct
import sys


# ==============================================================================
# 纯 Python 极简 Protobuf 编码器 (Zero Dependencies)
# ==============================================================================

WIRE_VARINT = 0
WIRE_LENGTH_DELIMITED = 2


def encode_varint(value: int) -> bytes:
    """编码无符号 varint。"""
    out = bytearray()
    while value > 0x7F:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value & 0x7F)
    return bytes(out)


def encode_tag(field_number: int, wire_type: int) -> bytes:
    """编码 protobuf 字段 tag。"""
    return encode_varint((field_number << 3) | wire_type)


def encode_string_field(field_number: int, text: str) -> bytes:
    """编码 string 字段 (wire_type = 2)。"""
    raw = text.encode("utf-8")
    return encode_tag(field_number, WIRE_LENGTH_DELIMITED) + encode_varint(len(raw)) + raw


def encode_varint_field(field_number: int, value: int) -> bytes:
    """编码 varint 字段 (wire_type = 0)。"""
    return encode_tag(field_number, WIRE_VARINT) + encode_varint(value)


def encode_message_field(field_number: int, message_bytes: bytes) -> bytes:
    """编码嵌入式 sub-message 字段 (wire_type = 2)。"""
    return encode_tag(field_number, WIRE_LENGTH_DELIMITED) + encode_varint(len(message_bytes)) + message_bytes


# ==============================================================================
# Mozc Protobuf 构造
# ==============================================================================

def build_mozc_entry(key: str, value: str, pos: int = 0, comment: str = "") -> bytes:
    """构造 mozc.user_dictionary.UserDictionary.Entry。
    
    field 1: string key (拼音)
    field 2: string value (词条汉字)
    field 3: uint32 pos (词性, 0 = NOUN 名词)
    field 4: string comment (备注)
    """
    buf = bytearray()
    buf.extend(encode_string_field(1, key))
    buf.extend(encode_string_field(2, value))
    if pos != 0:
        buf.extend(encode_varint_field(3, pos))
    if comment:
        buf.extend(encode_string_field(4, comment))
    return bytes(buf)


def build_mozc_dictionary(dict_id: int, name: str, entries: list) -> bytes:
    """构造 mozc.user_dictionary.UserDictionary。
    
    field 1: uint64 id
    field 2: string name
    field 3: repeated Entry entries
    """
    buf = bytearray()
    buf.extend(encode_varint_field(1, dict_id))
    buf.extend(encode_string_field(2, name))
    for entry_bytes in entries:
        buf.extend(encode_message_field(3, entry_bytes))
    return bytes(buf)


def build_mozc_storage(dictionaries: list) -> bytes:
    """构造 mozc.user_dictionary.UserDictionaryStorage。
    
    field 1: uint32 version = 1
    field 2: repeated UserDictionary dictionaries
    """
    buf = bytearray()
    buf.extend(encode_varint_field(1, 1))  # version = 1
    for dict_bytes in dictionaries:
        buf.extend(encode_message_field(2, dict_bytes))
    return bytes(buf)


# ==============================================================================
# 拼音清洗与标准化
# ==============================================================================

# 声调字符映射表
TONE_MAP = {
    'ā': 'a', 'á': 'a', 'ǎ': 'a', 'à': 'a',
    'ō': 'o', 'ó': 'o', 'ǒ': 'o', 'ò': 'o',
    'ē': 'e', 'é': 'e', 'ě': 'e', 'è': 'e',
    'ī': 'i', 'í': 'i', 'ǐ': 'i', 'ì': 'i',
    'ū': 'u', 'ú': 'u', 'ǔ': 'u', 'ù': 'u',
    'ü': 'v', 'ǖ': 'v', 'ǘ': 'v', 'ǚ': 'v', 'ǜ': 'v',
}

def clean_pinyin(raw: str) -> str:
    """将带声调或空格的拼音清理为纯 ASCII 小写字母。"""
    res = []
    for ch in raw.lower():
        if ch in TONE_MAP:
            res.append(TONE_MAP[ch])
        elif 'a' <= ch <= 'z':
            res.append(ch)
        elif ch in (' ', "'", '-', '_'):
            continue  # 忽略分词符
    return "".join(res)


# ==============================================================================
# 词库解析器
# ==============================================================================

def parse_rime_wanxiang(file_path: str, max_words: int = 100000) -> list:
    """解析 Rime 万象词库 (*.dict.yaml / *.txt)。"""
    entries = []
    in_yaml_header = False
    
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line == "---":
                in_yaml_header = True
                continue
            if line == "..." and in_yaml_header:
                in_yaml_header = False
                continue
            if in_yaml_header:
                continue

            # Rime 格式: 词条\t拼音\t权重  或 词条\t拼音
            parts = line.split("\t")
            if len(parts) >= 2:
                word = parts[0].strip()
                pinyin_raw = parts[1].strip()
                pinyin = clean_pinyin(pinyin_raw)
                if word and pinyin:
                    entries.append((pinyin, word))
            else:
                # 尝试空格分隔
                sp = line.split()
                if len(sp) >= 2:
                    word = sp[0].strip()
                    pinyin = clean_pinyin(sp[1].strip())
                    if word and pinyin:
                        entries.append((pinyin, word))

            if len(entries) >= max_words:
                print(f"[*] 达到最大词数上限 ({max_words})，截断处理。")
                break
                
    return entries


def parse_sogou_scel(file_path: str, max_words: int = 100000) -> list:
    """解析搜狗细胞词库 (*.scel 二进制格式)。"""
    with open(file_path, "rb") as f:
        data = f.read()

    # 验证搜狗 scel 文件签名
    if len(data) < 0x2628 or data[:4] != b"@\x15\x00\x00":
        # 很多 scel 文件头稍有不同，检查 0x1540 拼音偏移
        pass

    # 提取拼音索引表 (偏移 0x1540 到 0x2628)
    py_offset = 0x1540
    word_offset = 0x2628
    
    pinyin_table = {}
    pos = py_offset
    while pos < word_offset:
        if pos + 4 > len(data):
            break
        idx = struct.unpack("<H", data[pos:pos+2])[0]
        py_len = struct.unpack("<H", data[pos+2:pos+4])[0]
        pos += 4
        if pos + py_len > len(data):
            break
        pinyin = data[pos:pos+py_len].decode("utf-16le", errors="ignore")
        pinyin_table[idx] = clean_pinyin(pinyin)
        pos += py_len

    # 提取词条 (从 0x2628 开始)
    entries = []
    pos = word_offset
    while pos < len(data):
        if pos + 4 > len(data):
            break
        same_word_count = struct.unpack("<H", data[pos:pos+2])[0]
        py_index_count = struct.unpack("<H", data[pos+2:pos+4])[0]
        pos += 4
        
        # 读取拼音索引序列
        py_indices = []
        for _ in range(py_index_count // 2):
            if pos + 2 > len(data):
                break
            py_idx = struct.unpack("<H", data[pos:pos+2])[0]
            pos += 2
            if py_idx in pinyin_table:
                py_indices.append(pinyin_table[py_idx])
        full_pinyin = "".join(py_indices)

        # 读取相同拼音的词条
        for _ in range(same_word_count):
            if pos + 2 > len(data):
                break
            word_len = struct.unpack("<H", data[pos:pos+2])[0]
            pos += 2
            if pos + word_len > len(data):
                break
            word = data[pos:pos+word_len].decode("utf-16le", errors="ignore")
            pos += word_len
            
            # 跳过扩展信息 (12 字节)
            pos += 12
            
            if word and full_pinyin:
                entries.append((full_pinyin, word))
                if len(entries) >= max_words:
                    break

        if len(entries) >= max_words:
            break

    return entries


def parse_standard_txt(file_path: str, max_words: int = 100000) -> list:
    """解析通用 TXT 词库。
    
    兼容格式:
      拼音<TAB>词条
      词条<TAB>拼音
      拼音 词条
      词条 拼音
    """
    entries = []
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                parts = line.split()
            if len(parts) >= 2:
                col1, col2 = parts[0].strip(), parts[1].strip()
                # 判断哪一列是拼音 (全英文字符)
                clean1 = clean_pinyin(col1)
                clean2 = clean_pinyin(col2)
                if re.match(r'^[a-z]+$', clean1) and not re.match(r'^[a-z]+$', clean2):
                    entries.append((clean1, col2))
                elif re.match(r'^[a-z]+$', clean2) and not re.match(r'^[a-z]+$', clean1):
                    entries.append((clean2, col1))
                elif clean1 and col2:
                    entries.append((clean1, col2))

            if len(entries) >= max_words:
                break
    return entries


def convert_to_mozc_db(input_files: list, output_db: str, dict_name: str = "万象增强词库", max_words: int = 100000):
    """主转换流程：将多个词库源合并并生成 Mozc user_dictionary.db。"""
    all_entries = []
    seen = set()

    for path in input_files:
        if not os.path.exists(path):
            print(f"[!] 文件不存在: {path}")
            continue

        ext = os.path.splitext(path)[1].lower()
        print(f"[*] 正在解析: {path} (格式: {ext})")
        if ext == ".scel":
            items = parse_sogou_scel(path, max_words=max_words)
        elif ext in (".yaml", ".yml"):
            items = parse_rime_wanxiang(path, max_words=max_words)
        else:
            # 默认按通用文本/Rime 处理
            items = parse_rime_wanxiang(path, max_words=max_words)
            if not items:
                items = parse_standard_txt(path, max_words=max_words)

        for py, word in items:
            key_pair = (py, word)
            if key_pair not in seen:
                seen.add(key_pair)
                all_entries.append(key_pair)

        print(f"    已提取有效条目: {len(items)} 条，累计去重后: {len(all_entries)} 条")

    if not all_entries:
        print("[!] 未解析出任何有效词条，终止生成。")
        return False

    print(f"[*] 正在将 {len(all_entries)} 条词汇编码为 Mozc Protocol Buffers...")
    proto_entries = []
    for py, word in all_entries:
        entry_bytes = build_mozc_entry(key=py, value=word, pos=0, comment="gkx-import")
        proto_entries.append(entry_bytes)

    dict_bytes = build_mozc_dictionary(dict_id=1001, name=dict_name, entries=proto_entries)
    storage_bytes = build_mozc_storage(dictionaries=[dict_bytes])

    os.makedirs(os.path.dirname(os.path.abspath(output_db)), exist_ok=True)
    with open(output_db, "wb") as f:
        f.write(storage_bytes)

    file_size_kb = len(storage_bytes) / 1024.0
    print(f"[+] 转换成功！输出路径: {output_db} (大小: {file_size_kb:.2f} KB, 词数: {len(all_entries)})")
    return True


# ==============================================================================
# CLI 入口
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(description="外部词库转 Gboard iOS (Mozc) user_dictionary.db 转换器")
    parser.add_argument("inputs", nargs="+", help="输入词库文件路径 (支持 .dict.yaml, .scel, .txt)")
    parser.add_argument("-o", "--output", default="dist/user_dictionary.db", help="输出路径 (默认 dist/user_dictionary.db)")
    parser.add_argument("-n", "--name", default="万象搜狗词库", help="词库显示名称")
    parser.add_argument("--max", type=int, default=80000, help="最大词条数量限制 (默认 80000)")

    args = parser.parse_args()
    ok = convert_to_mozc_db(args.inputs, args.output, dict_name=args.name, max_words=args.max)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
