use std::{any::Any, fmt::Display};

pub fn message<E: Display + 'static>(error: E) -> String {
    let value = &error as &dyn Any;
    // Descriptions can contain credentials, URLs, SQL, or bound values.
    eprintln!("NoteBank failure: {}", std::any::type_name::<E>());
    if let Some(error) = value.downcast_ref::<rusqlite::Error>() {
        if let Some(code) = error.sqlite_error_code() { eprintln!("SQLite code: {code:?}"); }
        "NoteBank couldn't read or save its data. Try again."
    } else if let Some(error) = value.downcast_ref::<std::io::Error>() {
        eprintln!("File error kind: {:?}, OS code: {:?}", error.kind(), error.raw_os_error());
        "NoteBank couldn't access that file."
    } else if let Some(error) = value.downcast_ref::<reqwest::Error>() {
        eprintln!("Network status: {:?}, timeout: {}, connect: {}", error.status(), error.is_timeout(), error.is_connect());
        "Couldn't reach the Server."
    } else {
        "Something went wrong. Try again."
    }.to_owned()
}
