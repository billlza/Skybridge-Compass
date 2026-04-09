use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::de::{self, SeqAccess, Visitor};
use std::fmt;

pub mod bytes {
    use super::*;

    pub fn serialize<S>(bytes: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let encoded = STANDARD.encode(bytes);
        serializer.serialize_str(&encoded)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(BytesVisitor)
    }

    struct BytesVisitor;

    impl<'de> Visitor<'de> for BytesVisitor {
        type Value = Vec<u8>;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("base64 string or array of bytes")
        }

        fn visit_str<E>(self, v: &str) -> Result<Vec<u8>, E>
        where
            E: de::Error,
        {
            STANDARD.decode(v.as_bytes()).map_err(de::Error::custom)
        }

        fn visit_string<E>(self, v: String) -> Result<Vec<u8>, E>
        where
            E: de::Error,
        {
            self.visit_str(&v)
        }

        fn visit_bytes<E>(self, v: &[u8]) -> Result<Vec<u8>, E>
        where
            E: de::Error,
        {
            Ok(v.to_vec())
        }

        fn visit_seq<A>(self, mut seq: A) -> Result<Vec<u8>, A::Error>
        where
            A: SeqAccess<'de>,
        {
            let mut out = Vec::new();
            while let Some(value) = seq.next_element::<u8>()? {
                out.push(value);
            }
            Ok(out)
        }
    }
}

pub mod opt_bytes {
    use super::*;

    pub fn serialize<S>(bytes: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match bytes {
            Some(v) => {
                let encoded = STANDARD.encode(v);
                serializer.serialize_some(&encoded)
            }
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct OptVisitor;

        impl<'de> Visitor<'de> for OptVisitor {
            type Value = Option<Vec<u8>>;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("null, base64 string, or array of bytes")
            }

            fn visit_none<E>(self) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                Ok(None)
            }

            fn visit_unit<E>(self) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                Ok(None)
            }

            fn visit_some<D2>(self, deserializer: D2) -> Result<Self::Value, D2::Error>
            where
                D2: serde::Deserializer<'de>,
            {
                super::bytes::deserialize(deserializer).map(Some)
            }
        }

        deserializer.deserialize_option(OptVisitor)
    }
}
