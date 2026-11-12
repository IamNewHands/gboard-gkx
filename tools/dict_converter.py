#!/usr/bin/env python3
"""dict_converter.py — 外部词库转 Gboard iOS (Mozc) user_dictionary.db 转换器。

支持格式:
  1. Rime 万象方案词库 (*.dict.yaml / *.txt):
     格式如: 词条\t拼音\t权重 或 词条\t拼音
  2. 搜狗细胞词库 (*.scel):
     搜狗二进制细胞词库，自动解析 UTF-16LE 拼音表与词条
  3. 标准拼音/短语文本 (*.txt):
     格式如: 拼音<TAB>词条 或 词条<TAB>拼音
  4. 目录批量导入 (--dir <path>):
     自动扫描目录下的所有万象词库文件并按类别分组打包。

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
            continue
    return "".join(res)


# ==============================================================================
# 词库解析器
# ==============================================================================

def parse_rime_file(file_path: str, max_words: int = 150000) -> list:
    """解析单个 Rime 万象词库文件 (*.dict.yaml / *.txt)。
    
    返回: list of (weight: int, pinyin: str, word: str)
    """
    entries = []
    in_yaml_header = False

    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
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

            parts = line.split("\t")
            if len(parts) >= 2:
                word = parts[0].strip()
                pinyin = clean_pinyin(parts[1].strip())
                weight = int(parts[2].strip()) if len(parts) >= 3 and parts[2].strip().isdigit() else 0
                if word and pinyin:
                    entries.append((weight, pinyin, word))
            else:
                sp = line.split()
                if len(sp) >= 2:
                    word = sp[0].strip()
                    pinyin = clean_pinyin(sp[1].strip())
                    if word and pinyin:
                        entries.append((0, pinyin, word))

    # 按权重降序排序（高频词优先）
    if any(e[0] > 0 for e in entries):
        entries.sort(key=lambda x: x[0], reverse=True)

    if len(entries) > max_words:
        entries = entries[:max_words]

    return [(py, w) for (_, py, w) in entries]


def parse_sogou_scel(file_path: str, max_words: int = 150000) -> list:
    """解析搜狗细胞词库 (*.scel 二进制格式)。"""
    with open(file_path, "rb") as f:
        data = f.read()

    py_offset = 0x1540
    word_offset = 0x2628
    
    pinyin_table = {}
    pos = py_offset
    while pos < word_offset:
        if pos + 4 > len(data): break
        idx = struct.unpack("<H", data[pos:pos+2])[0]
        py_len = struct.unpack("<H", data[pos+2:pos+4])[0]
        pos += 4
        if pos + py_len > len(data): break
        pinyin = data[pos:pos+py_len].decode("utf-16le", errors="ignore")
        pinyin_table[idx] = clean_pinyin(pinyin)
        pos += py_len

    entries = []
    pos = word_offset
    while pos < len(data):
        if pos + 4 > len(data): break
        same_word_count = struct.unpack("<H", data[pos:pos+2])[0]
        py_index_count = struct.unpack("<H", data[pos+2:pos+4])[0]
        pos += 4
        
        py_indices = []
        for _ in range(py_index_count // 2):
            if pos + 2 > len(data): break
            py_idx = struct.unpack("<H", data[pos:pos+2])[0]
            pos += 2
            if py_idx in pinyin_table:
                py_indices.append(pinyin_table[py_idx])
        full_pinyin = "".join(py_indices)

        for _ in range(same_word_count):
            if pos + 2 > len(data): break
            word_len = struct.unpack("<H", data[pos:pos+2])[0]
            pos += 2
            if pos + word_len > len(data): break
            word = data[pos:pos+word_len].decode("utf-16le", errors="ignore")
            pos += word_len
            pos += 12  # skip ext
            
            if word and full_pinyin:
                entries.append((full_pinyin, word))
                if len(entries) >= max_words: break

        if len(entries) >= max_words: break

    return entries


# ==============================================================================
# 万象词库目录扫描与分类构建
# ==============================================================================

# 各类词库在 iOS 上的安全词条额度分配 (平衡丰富度与 Extension 内存占用)
DICT_LIMITS = {
    "top.dict.yaml": ("万象-Top高频", 175000),
    "chengyu.txt": ("万象-成语俗语", 40000),
    "diming.dict.yaml": ("万象-行政地名", 90000),
    "renming.dict.yaml": ("万象-现代人名", 25000),
    "mingren.dict.yaml": ("万象-历史名人", 25000),
    "yiren.dict.yaml": ("万象-演艺名人", 20000),
    "abbrev.dict.yaml": ("万象-缩写简语", 35000),
    "t9_abbrev.dict.yaml": ("万象-T9缩写", 35000),
    "huaxue.dict.yaml": ("万象-化学物质", 20000),
    "yixue.dict.yaml": ("万象-医学词汇", 20000),
    "yaopin.dict.yaml": ("万象-医药药品", 15000),
    "wuzhong.dict.yaml": ("万象-生物物种", 30000),
    "shici.dict.yaml": ("万象-经典诗词", 30000),
    "lianxiang.dict.yaml": ("万象-联想词组", 40000),
    "jichu.dict.yaml": ("万象-核心基础", 100000),
    "zi.dict.yaml": ("万象-单字全集", 55000),
    "en.dict.yaml": ("万象-英文词汇", 30000),
    "duoyin.dict.yaml": ("万象-多音字表", 10000),
    "cn&en.dict.yaml": ("万象-中英混输", 5000),
    "mixed.dict.yaml": ("万象-混合词表", 5000),
    "fangyan.dict.yaml": ("万象-方言俗话", 2000),
    "taifeng.dict.yaml": ("万象-台风命名", 1000),
    "cuoyin.dict.yaml": ("万象-错音纠错", 1000),
}


def build_from_directory(dir_path: str, output_db: str, max_total_words: int = 500000):
    """扫描目录下的所有万象词库文件并按类别打包成多词库 Protobuf。"""
    if not os.path.isdir(dir_path):
        print(f"[!] 目录不存在: {dir_path}")
        return False

    files = [f for f in os.listdir(dir_path) if f.endswith(('.yaml', '.txt', '.scel'))]
    if not files:
        print(f"[!] 目录下无有效词库文件: {dir_path}")
        return False

    print(f"[*] 发现 {len(files)} 个词库源文件，开始分类解析与编码...")

    mozc_dictionaries = []
    dict_id_counter = 1001
    total_words = 0
    global_seen = set()

    # 优先处理高频核心词库
    file_order = sorted(files, key=lambda x: 0 if "top" in x or "chengyu" in x else (1 if "jichu" not in x else 2))

    for fname in file_order:
        fpath = os.path.join(dir_path, fname)
        display_name, limit = DICT_LIMITS.get(fname, (os.path.splitext(fname)[0], 30000))

        if fname.endswith(".scel"):
            items = parse_sogou_scel(fpath, max_words=limit)
        else:
            items = parse_rime_file(fpath, max_words=limit)

        unique_items = []
        for py, w in items:
            key_pair = (py, w)
            if key_pair not in global_seen:
                global_seen.add(key_pair)
                unique_items.append(key_pair)
                if total_words + len(unique_items) >= max_total_words:
                    break

        if not unique_items:
            continue

        proto_entries = [build_mozc_entry(py, w, pos=0, comment="wanxiang") for py, w in unique_items]
        dict_bytes = build_mozc_dictionary(dict_id=dict_id_counter, name=display_name, entries=proto_entries)
        mozc_dictionaries.append(dict_bytes)
        dict_id_counter += 1
        total_words += len(unique_items)

        print(f"  [+] {display_name} ({fname}): 成功加载 {len(unique_items)} 词 (累计: {total_words})")

        if total_words >= max_total_words:
            print(f"[*] 已达到总词数上限安全红线 ({max_total_words})，停止载入以防 iOS Jetsam 杀扩展。")
            break

    print(f"[*] 正在生成 Mozc Protocol Buffers 二进制存储结构...")
    storage_bytes = build_mozc_storage(dictionaries=mozc_dictionaries)

    os.makedirs(os.path.dirname(os.path.abspath(output_db)), exist_ok=True)
    with open(output_db, "wb") as f:
        f.write(storage_bytes)

    size_mb = len(storage_bytes) / (1024.0 * 1024.0)
    print(f"[+] 成功构建综合词库！")
    print(f"    输出路径: {output_db}")
    print(f"    词库子类: {len(mozc_dictionaries)} 个")
    print(f"    词条总数: {total_words} 条")
    print(f"    文件大小: {size_mb:.2f} MB")
    return True


# ==============================================================================
# CLI 入口
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(description="外部词库转 Gboard iOS (Mozc) user_dictionary.db 转换器")
    parser.add_argument("inputs", nargs="*", help="输入词库文件路径 (支持 .dict.yaml, .scel, .txt)")
    parser.add_argument("--dir", help="输入词库目录路径，自动批量扫描并分类构建")
    parser.add_argument("-o", "--output", default="dist/user_dictionary.db", help="输出路径 (默认 dist/user_dictionary.db)")
    parser.add_argument("-n", "--name", default="万象词库", help="单词库显示名称")
    parser.add_argument("--max", type=int, default=500000, help="总词条数量安全上限 (默认 500,000)")

    args = parser.parse_args()

    if args.dir:
        ok = build_from_directory(args.dir, args.output, max_total_words=args.max)
    elif args.inputs:
        # 单文件列表转换
        all_entries = []
        seen = set()
        for p in args.inputs:
            ext = os.path.splitext(p)[1].lower()
            if ext == ".scel":
                items = parse_sogou_scel(p, max_words=args.max)
            else:
                items = parse_rime_file(p, max_words=args.max)
            for py, w in items:
                if (py, w) not in seen:
                    seen.add((py, w))
                    all_entries.append((py, w))
        proto_entries = [build_mozc_entry(py, w, pos=0, comment="import") for py, w in all_entries[:args.max]]
        dict_bytes = build_mozc_dictionary(dict_id=1001, name=args.name, entries=proto_entries)
        storage_bytes = build_mozc_storage(dictionaries=[dict_bytes])
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "wb") as f:
            f.write(storage_bytes)
        print(f"[+] 转换完成: {args.output} ({len(all_entries)} 词, {len(storage_bytes)/1024:.2f} KB)")
        ok = True
    else:
        parser.print_help()
        sys.exit(1)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
