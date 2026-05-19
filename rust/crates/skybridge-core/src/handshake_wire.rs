use anyhow::{Result, anyhow};

pub(crate) fn unwrap_handshake_padding(data: &[u8]) -> Vec<u8> {
    const HANDSHAKE_PADDING_MAGIC: &[u8; 4] = b"SBP1";
    if data.len() < 8 || &data[..4] != HANDSHAKE_PADDING_MAGIC {
        return data.to_vec();
    }
    let actual_len = u32::from_be_bytes([data[4], data[5], data[6], data[7]]) as usize;
    if actual_len > data.len().saturating_sub(8) {
        return data.to_vec();
    }
    data[8..(8 + actual_len)].to_vec()
}

pub(crate) fn encode_string(out: &mut Vec<u8>, value: &str) {
    let bytes = value.as_bytes();
    out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(bytes);
}

pub(crate) fn encode_string_array(out: &mut Vec<u8>, values: &[&str]) {
    out.extend_from_slice(&(values.len() as u32).to_le_bytes());
    for value in values {
        encode_string(out, value);
    }
}

pub(crate) fn append_u16_le(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_le_bytes());
}

pub(crate) fn read_u16_le(data: &[u8], offset: &mut usize) -> Result<u16> {
    let bytes = read_exact(data, offset, 2)?;
    Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
}

pub(crate) fn read_exact<'a>(data: &'a [u8], offset: &mut usize, len: usize) -> Result<&'a [u8]> {
    let end = offset
        .checked_add(len)
        .ok_or_else(|| anyhow!("length overflow"))?;
    let slice = data
        .get(*offset..end)
        .ok_or_else(|| anyhow!("truncated frame"))?;
    *offset = end;
    Ok(slice)
}
