//! Minimal zero-dependency JSON parser — just enough to read the statusline
//! payload Claude Code sends on stdin. Numbers are stored as f64; callers pull
//! the few fields they need by path.
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(BTreeMap<String, Json>),
}

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(m) => m.get(key),
            _ => None,
        }
    }
    /// Navigate a nested object path, e.g. ["context_window","used_percentage"].
    pub fn path(&self, keys: &[&str]) -> Option<&Json> {
        let mut cur = self;
        for k in keys {
            cur = cur.get(k)?;
        }
        Some(cur)
    }
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }
}

pub fn parse(s: &str) -> Option<Json> {
    let mut p = Parser { b: s.as_bytes(), i: 0 };
    p.ws();
    let v = p.value()?;
    Some(v)
}

/// Parse a stream of concatenated JSON documents (no separators required),
/// like `jq -s`. Stops at the first malformed document.
pub fn parse_all(s: &str) -> Vec<Json> {
    let mut p = Parser { b: s.as_bytes(), i: 0 };
    let mut docs = Vec::new();
    loop {
        p.ws();
        if p.i >= p.b.len() {
            break;
        }
        match p.value() {
            Some(v) => docs.push(v),
            None => break,
        }
    }
    docs
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }
    fn value(&mut self) -> Option<Json> {
        self.ws();
        if self.i >= self.b.len() {
            return None;
        }
        match self.b[self.i] {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => Some(Json::Str(self.string()?)),
            b't' => {
                self.lit("true")?;
                Some(Json::Bool(true))
            }
            b'f' => {
                self.lit("false")?;
                Some(Json::Bool(false))
            }
            b'n' => {
                self.lit("null")?;
                Some(Json::Null)
            }
            _ => self.number(),
        }
    }
    fn lit(&mut self, s: &str) -> Option<()> {
        if self.b[self.i..].starts_with(s.as_bytes()) {
            self.i += s.len();
            Some(())
        } else {
            None
        }
    }
    fn object(&mut self) -> Option<Json> {
        self.i += 1; // {
        let mut m = BTreeMap::new();
        self.ws();
        if self.i < self.b.len() && self.b[self.i] == b'}' {
            self.i += 1;
            return Some(Json::Obj(m));
        }
        loop {
            self.ws();
            let k = self.string()?;
            self.ws();
            if self.i >= self.b.len() || self.b[self.i] != b':' {
                return None;
            }
            self.i += 1;
            let v = self.value()?;
            m.insert(k, v);
            self.ws();
            if self.i >= self.b.len() {
                return None;
            }
            match self.b[self.i] {
                b',' => self.i += 1,
                b'}' => {
                    self.i += 1;
                    return Some(Json::Obj(m));
                }
                _ => return None,
            }
        }
    }
    fn array(&mut self) -> Option<Json> {
        self.i += 1; // [
        let mut a = Vec::new();
        self.ws();
        if self.i < self.b.len() && self.b[self.i] == b']' {
            self.i += 1;
            return Some(Json::Arr(a));
        }
        loop {
            let v = self.value()?;
            a.push(v);
            self.ws();
            if self.i >= self.b.len() {
                return None;
            }
            match self.b[self.i] {
                b',' => self.i += 1,
                b']' => {
                    self.i += 1;
                    return Some(Json::Arr(a));
                }
                _ => return None,
            }
        }
    }
    fn string(&mut self) -> Option<String> {
        if self.i >= self.b.len() || self.b[self.i] != b'"' {
            return None;
        }
        self.i += 1;
        let mut s = String::new();
        while self.i < self.b.len() {
            let c = self.b[self.i];
            match c {
                b'"' => {
                    self.i += 1;
                    return Some(s);
                }
                b'\\' => {
                    self.i += 1;
                    if self.i >= self.b.len() {
                        return None;
                    }
                    match self.b[self.i] {
                        b'"' => s.push('"'),
                        b'\\' => s.push('\\'),
                        b'/' => s.push('/'),
                        b'n' => s.push('\n'),
                        b't' => s.push('\t'),
                        b'r' => s.push('\r'),
                        b'b' => s.push('\u{08}'),
                        b'f' => s.push('\u{0C}'),
                        b'u' => {
                            if self.i + 5 > self.b.len() {
                                return None;
                            }
                            let hex = std::str::from_utf8(&self.b[self.i + 1..self.i + 5]).ok()?;
                            let cp = u32::from_str_radix(hex, 16).ok()?;
                            self.i += 4;
                            if (0xD800..=0xDBFF).contains(&cp) {
                                // high surrogate; expect a following \uXXXX low surrogate
                                if self.b.get(self.i + 1) == Some(&b'\\')
                                    && self.b.get(self.i + 2) == Some(&b'u')
                                    && self.i + 7 <= self.b.len()
                                {
                                    let hex2 =
                                        std::str::from_utf8(&self.b[self.i + 3..self.i + 7]).ok()?;
                                    let lo = u32::from_str_radix(hex2, 16).ok()?;
                                    self.i += 6;
                                    let full = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                    if let Some(ch) = char::from_u32(full) {
                                        s.push(ch);
                                    }
                                }
                            } else if let Some(ch) = char::from_u32(cp) {
                                s.push(ch);
                            }
                        }
                        _ => return None,
                    }
                    self.i += 1;
                }
                _ => {
                    let len = utf8_len(c);
                    let end = (self.i + len).min(self.b.len());
                    if let Ok(st) = std::str::from_utf8(&self.b[self.i..end]) {
                        s.push_str(st);
                    }
                    self.i = end;
                }
            }
        }
        None
    }
    fn number(&mut self) -> Option<Json> {
        let start = self.i;
        if self.i < self.b.len() && (self.b[self.i] == b'-' || self.b[self.i] == b'+') {
            self.i += 1;
        }
        while self.i < self.b.len()
            && matches!(self.b[self.i], b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-')
        {
            self.i += 1;
        }
        let tok = std::str::from_utf8(&self.b[start..self.i]).ok()?;
        tok.parse::<f64>().ok().map(Json::Num)
    }
}

fn utf8_len(b: u8) -> usize {
    if b < 0x80 {
        1
    } else if b >> 5 == 0b110 {
        2
    } else if b >> 4 == 0b1110 {
        3
    } else if b >> 3 == 0b11110 {
        4
    } else {
        1
    }
}
