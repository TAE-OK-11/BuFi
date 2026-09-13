// SPDX-License-Identifier: GPL-3.0-or-later

use std::{
    collections::{BTreeMap, HashSet},
    net::IpAddr,
    ptr, slice, str,
};

const MAX_DOMAIN_BYTES: usize = 253;
const MAX_LABELS: usize = 128;

#[derive(Clone, Copy)]
enum RuleAction {
    Block,
    Allow,
}

struct ParsedRules {
    blocked: Vec<u8>,
    allowed: Vec<u8>,
    ignored: usize,
    reached_limit: bool,
}

struct RuleSets {
    blocked: HashSet<String>,
    allowed: HashSet<String>,
    ignored: usize,
    reached_limit: bool,
}

impl RuleSets {
    fn new() -> Self {
        Self::with_capacity(0)
    }

    fn with_capacity(capacity: usize) -> Self {
        Self {
            blocked: HashSet::with_capacity(capacity),
            allowed: HashSet::with_capacity(capacity / 16),
            ignored: 0,
            reached_limit: false,
        }
    }

    fn rule_count(&self) -> usize {
        self.blocked.len().saturating_add(self.allowed.len())
    }
}

fn input_bytes<'a>(bytes: *const u8, count: usize) -> Option<&'a [u8]> {
    if count == 0 {
        return Some(&[]);
    }
    if bytes.is_null() {
        return None;
    }
    // SAFETY: every exported caller contract requires a readable buffer for the
    // synchronous duration of the call, and the null case is rejected above.
    Some(unsafe { slice::from_raw_parts(bytes, count) })
}

fn parse_rules(
    input: &[u8],
    default_action: RuleAction,
    maximum_rules: usize,
    rules: &mut RuleSets,
) -> Result<usize, ()> {
    let text = str::from_utf8(input).map_err(|_| ())?;
    let stop_at = maximum_rules.saturating_add(1);
    let mut usable_rule_count = 0usize;

    for raw_line in text.split(['\n', '\r']) {
        let line = raw_line.trim();
        if line.is_empty()
            || line.starts_with('!')
            || line.starts_with('#')
            || (line.starts_with('[') && line.ends_with(']'))
        {
            continue;
        }

        for raw_value in raw_line.split(',') {
            let value = raw_value.trim();
            let is_exception = value.starts_with("@@");
            let domains = normalized_domains(value);
            if domains.is_empty() {
                rules.ignored = rules.ignored.saturating_add(1);
                continue;
            }
            usable_rule_count = usable_rule_count.saturating_add(domains.len());
            let action = if is_exception {
                RuleAction::Allow
            } else {
                default_action
            };
            for domain in domains {
                match action {
                    RuleAction::Block => {
                        rules.blocked.insert(domain);
                    }
                    RuleAction::Allow => {
                        rules.allowed.insert(domain);
                    }
                }
            }
            if rules.rule_count() >= stop_at {
                rules.reached_limit = true;
                return Ok(usable_rule_count);
            }
        }
    }
    Ok(usable_rule_count)
}

fn normalized_domains(raw_value: &str) -> Vec<String> {
    let mut value = raw_value.trim().to_ascii_lowercase();
    if value.is_empty()
        || value.starts_with('!')
        || value.starts_with('#')
        || value.contains("##")
        || value.contains("#@#")
        || value.contains("#$#")
        || value.contains("#?#")
    {
        return Vec::new();
    }

    if let Some(comment) = value.find('#') {
        value.truncate(comment);
        value = value.trim().to_owned();
    }
    if value.is_empty() {
        return Vec::new();
    }
    if value.starts_with("@@") {
        value.drain(..2);
    }

    let hosts_parts: Vec<&str> = value
        .split(|character| character == ' ' || character == '\t')
        .filter(|part| !part.is_empty())
        .collect();
    if hosts_parts.len() >= 2 && hosts_parts[0].parse::<IpAddr>().is_ok() {
        return hosts_parts[1..]
            .iter()
            .filter_map(|part| normalize_domain_token(part))
            .collect();
    }

    normalize_domain_token(&value).into_iter().collect()
}

fn normalize_domain_token(raw_value: &str) -> Option<String> {
    let mut value = raw_value.trim().to_ascii_lowercase();
    if value.is_empty() || value.starts_with('/') {
        return None;
    }
    if value.starts_with("||") {
        value.drain(..2);
    } else if value.starts_with('|') {
        value.drain(..1);
    }

    if value.starts_with("http://") || value.starts_with("https://") {
        value = http_host(&value)?;
    } else if value.starts_with("//") {
        value = http_host(&format!("https:{value}"))?;
    } else {
        if let Some(delimiter) = value.find(['^', '$']) {
            value.truncate(delimiter);
        }
        if value.contains('/') {
            return None;
        }
    }

    while value.starts_with("*.") {
        value.drain(..2);
    }
    value = value.trim_matches(['.', '|']).to_owned();
    if value.parse::<IpAddr>().is_ok() || !is_valid_domain(&value) {
        return None;
    }
    Some(value)
}

fn http_host(url: &str) -> Option<String> {
    let scheme_end = url.find("://")?;
    let remainder = &url[scheme_end + 3..];
    let authority_end = remainder.find(['/', '?', '#']).unwrap_or(remainder.len());
    let authority = &remainder[..authority_end];
    let host_port = authority.rsplit('@').next()?;
    if host_port.starts_with('[') {
        let end = host_port.find(']')?;
        return Some(host_port[1..end].to_owned());
    }
    let host = host_port.split(':').next()?;
    (!host.is_empty()).then(|| host.to_owned())
}

fn is_valid_domain(value: &str) -> bool {
    if value.is_empty() || value.len() > MAX_DOMAIN_BYTES || !value.is_ascii() {
        return false;
    }
    value.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    })
}

fn snapshot<'a>(domains: impl Iterator<Item = &'a String>) -> (Vec<u8>, usize) {
    let mut ordered: Vec<&String> = domains.collect();
    ordered.sort_unstable();
    let mut output = Vec::new();
    for domain in &ordered {
        output.extend_from_slice(domain.as_bytes());
        output.push(b'\n');
    }
    (output, ordered.len())
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_parse_rules(
    bytes: *const u8,
    count: usize,
    default_action: u8,
    maximum_rules: usize,
) -> *mut ParsedRules {
    let Some(input) = input_bytes(bytes, count) else {
        return ptr::null_mut();
    };
    let action = if default_action == 0 {
        RuleAction::Block
    } else {
        RuleAction::Allow
    };
    let estimated_rules = input
        .len()
        .saturating_div(24)
        .min(maximum_rules.saturating_add(1));
    let mut rules = RuleSets::with_capacity(estimated_rules);
    if parse_rules(input, action, maximum_rules, &mut rules).is_err() {
        return ptr::null_mut();
    }
    let (blocked, _) = snapshot(rules.blocked.iter());
    let (allowed, _) = snapshot(rules.allowed.iter());
    Box::into_raw(Box::new(ParsedRules {
        blocked,
        allowed,
        ignored: rules.ignored,
        reached_limit: rules.reached_limit,
    }))
}

fn parsed_bytes(
    handle: *const ParsedRules,
    output_count: *mut usize,
    select: impl FnOnce(&ParsedRules) -> &[u8],
) -> *const u8 {
    if handle.is_null() || output_count.is_null() {
        return ptr::null();
    }
    // SAFETY: Swift keeps the opaque parse handle alive until the matching free.
    let parsed = unsafe { &*handle };
    let bytes = select(parsed);
    // SAFETY: output_count was validated and points to a writable Swift Int.
    unsafe { *output_count = bytes.len() };
    if bytes.is_empty() {
        ptr::null()
    } else {
        bytes.as_ptr()
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_parsed_blocked(
    handle: *const ParsedRules,
    output_count: *mut usize,
) -> *const u8 {
    parsed_bytes(handle, output_count, |parsed| &parsed.blocked)
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_parsed_allowed(
    handle: *const ParsedRules,
    output_count: *mut usize,
) -> *const u8 {
    parsed_bytes(handle, output_count, |parsed| &parsed.allowed)
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_parsed_ignored(handle: *const ParsedRules) -> usize {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the handle is immutable and owned by the caller for this call.
    unsafe { (*handle).ignored }
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_parsed_reached_limit(handle: *const ParsedRules) -> u8 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the handle is immutable and owned by the caller for this call.
    u8::from(unsafe { (*handle).reached_limit })
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_parsed_free(handle: *mut ParsedRules) {
    if !handle.is_null() {
        // SAFETY: ownership is returned exactly once by the Swift adapter.
        drop(unsafe { Box::from_raw(handle) });
    }
}

struct BlocklistCompiler {
    maximum_rules: usize,
    rules: RuleSets,
    compiled_snapshot: Vec<u8>,
    compiled_rule_count: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_compiler_create(maximum_rules: usize) -> *mut BlocklistCompiler {
    Box::into_raw(Box::new(BlocklistCompiler {
        maximum_rules,
        rules: RuleSets::with_capacity(maximum_rules.min(50_000)),
        compiled_snapshot: Vec::new(),
        compiled_rule_count: 0,
    }))
}

/// Returns 0 on success, 1 for invalid UTF-8, 2 when the global unique-rule
/// bound is exceeded, and -1 for an invalid handle or buffer.
#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_compiler_add(
    handle: *mut BlocklistCompiler,
    bytes: *const u8,
    count: usize,
    usable_rule_count: *mut usize,
) -> i32 {
    if handle.is_null() || usable_rule_count.is_null() {
        return -1;
    }
    let Some(input) = input_bytes(bytes, count) else {
        return -1;
    };
    // SAFETY: the compiler is actor-owned by Swift and exclusively borrowed here.
    let compiler = unsafe { &mut *handle };
    compiler.compiled_snapshot.clear();
    compiler.compiled_rule_count = 0;
    match parse_rules(
        input,
        RuleAction::Block,
        compiler.maximum_rules,
        &mut compiler.rules,
    ) {
        Ok(usable) => {
            // SAFETY: the out pointer was validated above.
            unsafe { *usable_rule_count = usable };
            if compiler.rules.reached_limit { 2 } else { 0 }
        }
        Err(()) => 1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_compiler_finish(
    handle: *mut BlocklistCompiler,
    output_count: *mut usize,
    output_rule_count: *mut usize,
) -> *const u8 {
    if handle.is_null() || output_count.is_null() || output_rule_count.is_null() {
        return ptr::null();
    }
    // SAFETY: the compiler is actor-owned by Swift and exclusively borrowed here.
    let compiler = unsafe { &mut *handle };
    let (compiled, rule_count) = snapshot(
        compiler
            .rules
            .blocked
            .iter()
            .filter(|domain| !compiler.rules.allowed.contains(*domain)),
    );
    compiler.compiled_snapshot = compiled;
    compiler.compiled_rule_count = rule_count;
    // SAFETY: both out pointers were validated above.
    unsafe {
        *output_count = compiler.compiled_snapshot.len();
        *output_rule_count = compiler.compiled_rule_count;
    }
    if compiler.compiled_snapshot.is_empty() {
        ptr::null()
    } else {
        compiler.compiled_snapshot.as_ptr()
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_compiler_free(handle: *mut BlocklistCompiler) {
    if !handle.is_null() {
        // SAFETY: ownership is returned exactly once by the Swift adapter.
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[derive(Default)]
struct TrieNode {
    terminal: bool,
    children: BTreeMap<Vec<u8>, usize>,
}

struct DomainSuffixMatcher {
    nodes: Vec<TrieNode>,
}

impl DomainSuffixMatcher {
    fn new() -> Self {
        Self {
            nodes: vec![TrieNode::default()],
        }
    }

    fn insert(&mut self, domain: &str) {
        let mut node_index = 0usize;
        for label in domain.as_bytes().split(|byte| *byte == b'.').rev() {
            if let Some(child) = self.nodes[node_index].children.get(label).copied() {
                node_index = child;
                continue;
            }
            let child = self.nodes.len();
            self.nodes.push(TrieNode::default());
            self.nodes[node_index]
                .children
                .insert(label.to_vec(), child);
            node_index = child;
        }
        self.nodes[node_index].terminal = true;
    }

    fn from_rule_bytes(bytes: &[u8]) -> Self {
        let mut matcher = Self::new();
        let Ok(text) = str::from_utf8(bytes) else {
            return matcher;
        };
        for raw_value in text.split(['\n', '\r', ',']) {
            for domain in normalized_domains(raw_value) {
                matcher.insert(&domain);
            }
        }
        matcher
    }

    fn matches(&self, question: &ParsedQuestion) -> bool {
        let mut node_index = 0usize;
        for label_index in (0..question.label_count).rev() {
            let label = question.label(label_index);
            let Some(child) = self.nodes[node_index].children.get(label).copied() else {
                return false;
            };
            node_index = child;
            if self.nodes[node_index].terminal {
                return true;
            }
        }
        false
    }
}

struct ParsedQuestion {
    domain: [u8; MAX_DOMAIN_BYTES],
    domain_len: usize,
    label_starts: [u8; MAX_LABELS],
    label_count: usize,
    message_end: usize,
}

impl ParsedQuestion {
    fn label(&self, index: usize) -> &[u8] {
        let start = usize::from(self.label_starts[index]);
        let end = if index + 1 < self.label_count {
            usize::from(self.label_starts[index + 1]).saturating_sub(1)
        } else {
            self.domain_len
        };
        &self.domain[start..end]
    }

    fn suffix(&self, index: usize) -> &[u8] {
        let start = usize::from(self.label_starts[index]);
        &self.domain[start..self.domain_len]
    }
}

fn read_u16(data: &[u8], offset: usize) -> Option<u16> {
    let high = *data.get(offset)?;
    let low = *data.get(offset + 1)?;
    Some((u16::from(high) << 8) | u16::from(low))
}

fn parse_question(data: &[u8]) -> Option<ParsedQuestion> {
    let flags = read_u16(data, 2)?;
    if data.len() < 17 || flags & 0x8000 != 0 || flags & 0x7800 != 0 || read_u16(data, 4)? != 1 {
        return None;
    }

    let mut question = ParsedQuestion {
        domain: [0; MAX_DOMAIN_BYTES],
        domain_len: 0,
        label_starts: [0; MAX_LABELS],
        label_count: 0,
        message_end: 0,
    };
    let mut offset = 12usize;
    let mut next_offset = None;
    let mut pointer_depth = 0usize;

    loop {
        let length = usize::from(*data.get(offset)?);
        if length == 0 {
            let end = next_offset.unwrap_or(offset + 1);
            question.message_end = end.checked_add(4)?;
            break;
        }
        if length & 0xc0 == 0xc0 {
            let low = usize::from(*data.get(offset + 1)?);
            let pointer = ((length & 0x3f) << 8) | low;
            if pointer >= data.len() || pointer_depth >= 8 {
                return None;
            }
            if next_offset.is_none() {
                next_offset = Some(offset + 2);
            }
            pointer_depth += 1;
            offset = pointer;
            continue;
        }
        if length > 63 || length & 0xc0 != 0 || question.label_count >= MAX_LABELS {
            return None;
        }
        let label_start = offset.checked_add(1)?;
        let label_end = label_start.checked_add(length)?;
        let label = data.get(label_start..label_end)?;
        if !label.is_ascii() || str::from_utf8(label).is_err() {
            return None;
        }
        let separator = usize::from(question.label_count > 0);
        let required = question
            .domain_len
            .checked_add(separator)?
            .checked_add(length)?;
        if required > MAX_DOMAIN_BYTES {
            return None;
        }
        if separator == 1 {
            question.domain[question.domain_len] = b'.';
            question.domain_len += 1;
        }
        question.label_starts[question.label_count] = u8::try_from(question.domain_len).ok()?;
        for byte in label {
            question.domain[question.domain_len] = byte.to_ascii_lowercase();
            question.domain_len += 1;
        }
        question.label_count += 1;
        offset = label_end;
    }

    if question.label_count == 0
        || question.message_end > data.len()
        || read_u16(data, question.message_end - 2)? != 1
    {
        return None;
    }
    Some(question)
}

fn snapshot_index(data: &[u8]) -> Option<Vec<usize>> {
    if data.is_empty() {
        return Some(Vec::new());
    }
    if data.last() != Some(&b'\n') {
        return None;
    }
    let mut starts = vec![0usize];
    let mut previous: Option<&[u8]> = None;
    let mut start = 0usize;
    for (index, byte) in data.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }
        let line = &data[start..index];
        let text = str::from_utf8(line).ok()?;
        if !is_valid_domain(text) || previous.is_some_and(|value| value >= line) {
            return None;
        }
        previous = Some(line);
        start = index + 1;
        if start < data.len() {
            starts.push(start);
        }
    }
    (start == data.len()).then_some(starts)
}

fn compare_line(data: &[u8], starts: &[usize], line: usize, query: &[u8]) -> std::cmp::Ordering {
    let start = starts[line];
    let end = if line + 1 < starts.len() {
        starts[line + 1] - 1
    } else {
        data.len() - 1
    };
    data[start..end].cmp(query)
}

fn snapshot_contains(data: &[u8], starts: &[usize], query: &[u8]) -> bool {
    let mut lower = 0usize;
    let mut upper = starts.len();
    while lower < upper {
        let middle = lower + (upper - lower) / 2;
        if compare_line(data, starts, middle, query).is_lt() {
            lower = middle + 1;
        } else {
            upper = middle;
        }
    }
    lower < starts.len() && compare_line(data, starts, lower, query).is_eq()
}

struct DnsFilter {
    blocked: DomainSuffixMatcher,
    allowed: DomainSuffixMatcher,
    subscription_line_starts: Vec<usize>,
    subscription_length: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_filter_create(
    blocked_bytes: *const u8,
    blocked_count: usize,
    allowed_bytes: *const u8,
    allowed_count: usize,
    subscription_bytes: *const u8,
    subscription_count: usize,
) -> *mut DnsFilter {
    let Some(blocked) = input_bytes(blocked_bytes, blocked_count) else {
        return ptr::null_mut();
    };
    let Some(allowed) = input_bytes(allowed_bytes, allowed_count) else {
        return ptr::null_mut();
    };
    let Some(subscription) = input_bytes(subscription_bytes, subscription_count) else {
        return ptr::null_mut();
    };
    let (subscription_line_starts, subscription_length) = match snapshot_index(subscription) {
        Some(starts) => (starts, subscription.len()),
        None => (Vec::new(), 0),
    };
    Box::into_raw(Box::new(DnsFilter {
        blocked: DomainSuffixMatcher::from_rule_bytes(blocked),
        allowed: DomainSuffixMatcher::from_rule_bytes(allowed),
        subscription_line_starts,
        subscription_length,
    }))
}

/// Returns the end of the DNS question when it should be blocked. Zero means
/// pass through; negative values indicate an invalid handle or borrowed buffer.
#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_filter_blocked_message_end(
    handle: *const DnsFilter,
    query_bytes: *const u8,
    query_count: usize,
    subscription_bytes: *const u8,
    subscription_count: usize,
) -> isize {
    if handle.is_null() {
        return -1;
    }
    let Some(query) = input_bytes(query_bytes, query_count) else {
        return -1;
    };
    let Some(subscription) = input_bytes(subscription_bytes, subscription_count) else {
        return -1;
    };
    // SAFETY: the immutable filter handle is retained by Swift for this call and
    // can be shared across resolver callbacks.
    let filter = unsafe { &*handle };
    let Some(question) = parse_question(query) else {
        return 0;
    };
    if filter.allowed.matches(&question) {
        return 0;
    }
    let custom_blocked = filter.blocked.matches(&question);
    let subscription_blocked = subscription.len() == filter.subscription_length
        && !filter.subscription_line_starts.is_empty()
        && (0..question.label_count).any(|index| {
            snapshot_contains(
                subscription,
                &filter.subscription_line_starts,
                question.suffix(index),
            )
        });
    if custom_blocked || subscription_blocked {
        isize::try_from(question.message_end).unwrap_or(-1)
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_dns_filter_free(handle: *mut DnsFilter) {
    if !handle.is_null() {
        // SAFETY: ownership is returned exactly once by the Swift adapter.
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dns_query(domain: &str) -> Vec<u8> {
        let mut query = vec![0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
        for label in domain.split('.') {
            query.push(label.len() as u8);
            query.extend_from_slice(label.as_bytes());
        }
        query.extend_from_slice(&[0, 0, 1, 0, 1]);
        query
    }

    #[test]
    fn parses_supported_rule_formats_and_exceptions() {
        let mut rules = RuleSets::new();
        parse_rules(
            b"||ads.example^\n@@||music.ads.example^\n0.0.0.0 tracker.example metrics.example\npage.example##.ad",
            RuleAction::Block,
            20,
            &mut rules,
        )
        .unwrap();
        let (blocked, _) = snapshot(rules.blocked.iter());
        let (allowed, _) = snapshot(rules.allowed.iter());
        assert_eq!(blocked, b"ads.example\nmetrics.example\ntracker.example\n");
        assert_eq!(allowed, b"music.ads.example\n");
        assert_eq!(rules.ignored, 1);
    }

    #[test]
    fn compiler_deduplicates_and_removes_exceptions() {
        let mut rules = RuleSets::new();
        parse_rules(
            b"ads.example\ntracker.example\n@@||ads.example^",
            RuleAction::Block,
            20,
            &mut rules,
        )
        .unwrap();
        let (compiled, count) = snapshot(
            rules
                .blocked
                .iter()
                .filter(|domain| !rules.allowed.contains(*domain)),
        );
        assert_eq!(compiled, b"tracker.example\n");
        assert_eq!(count, 1);
    }

    #[test]
    fn matcher_honors_allow_rules_and_whole_labels() {
        let blocked = DomainSuffixMatcher::from_rule_bytes(b"example.com\n");
        let allowed = DomainSuffixMatcher::from_rule_bytes(b"music.example.com\n");
        let blocked_question = parse_question(&dns_query("deep.ads.example.com")).unwrap();
        let allowed_question = parse_question(&dns_query("music.example.com")).unwrap();
        let unrelated_question = parse_question(&dns_query("notexample.com")).unwrap();
        assert!(blocked.matches(&blocked_question));
        assert!(allowed.matches(&allowed_question));
        assert!(!blocked.matches(&unrelated_question));
    }

    #[test]
    fn sorted_snapshot_matches_parent_suffixes() {
        let data = b"deep.example.net\nexample.com\nmetrics.deep.example.net\n";
        let starts = snapshot_index(data).unwrap();
        let question = parse_question(&dns_query("a.metrics.deep.example.net")).unwrap();
        assert!((0..question.label_count).any(|index| snapshot_contains(
            data,
            &starts,
            question.suffix(index)
        )));
    }
}
