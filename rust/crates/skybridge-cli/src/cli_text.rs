pub(crate) fn shell_quote(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | ':' | '='))
    {
        value.to_owned()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}

pub(crate) fn tail_lossy(bytes: &[u8], max_chars: usize) -> String {
    let text = String::from_utf8_lossy(bytes);
    let char_count = text.chars().count();
    if char_count <= max_chars {
        return text.into_owned();
    }

    let tail = text
        .chars()
        .rev()
        .take(max_chars)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<String>();
    format!("...[truncated]\n{tail}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quote_preserves_safe_values_and_quotes_shell_sensitive_values() {
        assert_eq!(shell_quote("/tmp/a-b:c=1"), "/tmp/a-b:c=1");
        assert_eq!(shell_quote("two words"), "'two words'");
        assert_eq!(shell_quote("can't"), "'can'\\''t'");
    }

    #[test]
    fn tail_lossy_preserves_short_text_and_truncates_by_chars() {
        assert_eq!(tail_lossy("short".as_bytes(), 10), "short");
        assert_eq!(tail_lossy("abcdef".as_bytes(), 3), "...[truncated]\ndef");
    }
}
