//! Deterministic encoding helpers for handshake compatibility.

#[derive(Debug, Default)]
pub struct DeterministicEncoder {
    data: Vec<u8>,
}

impl DeterministicEncoder {
    pub fn new() -> Self {
        Self { data: Vec::new() }
    }

    pub fn encode_u32(&mut self, value: u32) {
        self.data.extend_from_slice(&value.to_le_bytes());
    }

    pub fn encode_bool(&mut self, value: bool) {
        self.data.push(if value { 0x01 } else { 0x00 });
    }

    pub fn encode_bytes(&mut self, value: &[u8]) {
        self.encode_u32(value.len() as u32);
        self.data.extend_from_slice(value);
    }

    pub fn encode_string(&mut self, value: &str) {
        self.encode_bytes(value.as_bytes());
    }

    pub fn encode_string_array(&mut self, values: &[String]) {
        self.encode_u32(values.len() as u32);
        for value in values {
            self.encode_string(value);
        }
    }

    pub fn finalize(self) -> Vec<u8> {
        self.data
    }
}

#[derive(Debug)]
pub struct DeterministicDecoder<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> DeterministicDecoder<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, offset: 0 }
    }

    pub fn is_at_end(&self) -> bool {
        self.offset >= self.data.len()
    }

    pub fn decode_u8(&mut self) -> Option<u8> {
        if self.offset + 1 > self.data.len() {
            return None;
        }
        let value = self.data[self.offset];
        self.offset += 1;
        Some(value)
    }

    pub fn decode_u32(&mut self) -> Option<u32> {
        if self.offset + 4 > self.data.len() {
            return None;
        }
        let value = u32::from_le_bytes([
            self.data[self.offset],
            self.data[self.offset + 1],
            self.data[self.offset + 2],
            self.data[self.offset + 3],
        ]);
        self.offset += 4;
        Some(value)
    }

    pub fn decode_bool(&mut self) -> Option<bool> {
        self.decode_u8().map(|b| b != 0)
    }

    pub fn decode_bytes(&mut self) -> Option<Vec<u8>> {
        let len = self.decode_u32()? as usize;
        if self.offset + len > self.data.len() {
            return None;
        }
        let bytes = self.data[self.offset..self.offset + len].to_vec();
        self.offset += len;
        Some(bytes)
    }

    pub fn decode_string(&mut self) -> Option<String> {
        let bytes = self.decode_bytes()?;
        String::from_utf8(bytes).ok()
    }

    pub fn decode_string_array(&mut self) -> Option<Vec<String>> {
        let count = self.decode_u32()? as usize;
        let mut values = Vec::with_capacity(count);
        for _ in 0..count {
            values.push(self.decode_string()?);
        }
        Some(values)
    }
}
