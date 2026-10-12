//! Nook's PromptDeck, shared so every shell asks the same questions.

pub const PROMPTS: &[&str] = &[
    "What surprised you today?",
    "What would you tell yourself a year ago?",
    "Describe where you are right now — all five senses.",
    "What's the smallest thing that made you smile lately?",
    "What are you avoiding writing about?",
    "Who did you last have a real conversation with?",
    "What did you almost do today?",
    "What's changed since this time last month?",
    "Write about something you're looking forward to.",
    "What's a question you can't answer yet?",
    "What did you notice on the way somewhere today?",
    "What would you do with a free afternoon tomorrow?",
    "What's worth remembering about this week?",
    "Describe today in exactly three sentences.",
    "What are you carrying that you could put down?",
    "What did you learn the hard way recently?",
    "Write the first paragraph of the story of today.",
    "What sound, smell, or taste took you somewhere else?",
    "What do you want more of? Less of?",
    "Who deserves a thank-you you haven't sent?",
];

/// The prompt for a date (`YYYY-MM-DD`), the same on every shell.
pub fn prompt_of_day(date: &str) -> &'static str {
    let h = date.bytes().fold(0u32, |h, b| h.wrapping_mul(31).wrapping_add(b as u32));
    PROMPTS[(h as usize) % PROMPTS.len()]
}

/// The prompt `n` steps after the day's.
pub fn prompt_after(date: &str, n: usize) -> &'static str {
    let i = PROMPTS.iter().position(|p| *p == prompt_of_day(date)).unwrap_or(0);
    PROMPTS[(i + n) % PROMPTS.len()]
}
