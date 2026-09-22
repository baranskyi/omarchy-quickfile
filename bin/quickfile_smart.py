#!/usr/bin/env python3
"""Dependency-free smart-search plan helpers shared by QuickFile processes.

The optional model only supplies small typed hints.  This module owns the
bounded wire format and the deterministic part of query parsing so the main
filesystem backend never needs to import torch or transformers.
"""

from __future__ import annotations

import math
import re
from typing import Any


SMART_PLAN_VERSION = 1
SMART_QUERY_LIMIT = 512
SMART_PLAN_LIMIT = 16 * 1024
SMART_TERM_LIMIT = 8
SMART_TERM_LENGTH_LIMIT = 64
# Measured on the pinned multilingual checkpoint: below 0.75 its hints for
# queries that name no kind or time are mostly noise (a spurious "older" at
# 0.5-0.65, "config" for a lease agreement at 0.5), while correct hints for
# explicit requests land at 0.8-1.0.
SMART_CONFIDENCE_MIN = 0.75

SMART_HINT_VALUES = {
    "target": {"any", "file", "folder"},
    "kind": {
        "any", "document", "code", "config", "image", "audio", "video", "archive",
    },
    "location": {"any", "name", "path", "content"},
    "time": {
        "any", "today", "yesterday", "this-week", "last-week",
        "this-month", "last-month", "older",
    },
}


class SmartPlanError(ValueError):
    """Raised when an untrusted smart-search plan violates its wire contract."""


_SEARCH_WORDS = {
    # English query scaffolding.
    "a", "about", "all", "an", "and", "any", "are", "at", "by", "called", "can", "did",
    "do", "file", "files", "find", "edited", "for", "from", "get", "give", "had", "has",
    "have", "i", "in", "into", "is", "it", "last", "locate", "looking", "me", "modified",
    "my", "need", "of", "on", "or", "please", "previous", "put", "search", "show",
    "some", "something", "that", "the", "there", "this", "to", "want", "was", "where",
    "which", "with",
    # Russian query scaffolding and common inflections.
    "а", "в", "во", "где", "дай", "для", "за", "и", "из", "или", "ищу", "к", "как",
    "который", "которого", "которые", "которую", "лежит", "мне", "мой", "моя", "мои",
    "мою", "на", "найди", "найдите", "найти", "нашёл", "не", "нужен", "нужна", "нужно",
    "о", "об", "от", "по", "покажи", "показать", "поиск", "правил", "предыдущая",
    "предыдущего", "предыдущий", "про", "прошлая", "прошлого", "прошлую", "прошлый",
    "редактировал", "с", "со", "тот", "ту", "файл", "файла", "файле", "файлы", "что",
    "эта", "эти", "этого", "этой", "этот", "это", "я",
    # Ukrainian query scaffolding.
    "де", "з", "зі", "знайди", "знайдіть", "знайти", "із", "мені", "мій", "моє", "мої",
    "пошук", "потрібен", "потрібна", "потрібно", "правив", "редагував", "та", "той",
    "файли", "файлів", "файлу", "це", "цей", "ця", "ці", "що", "шукай", "шукаю", "яка",
    "яке", "який", "які",
}

_CONTROL_WORDS = {
    "archive", "archives", "audio", "code", "config", "configs", "configuration",
    "content", "contents", "directory", "document", "documents", "folder", "folders",
    "image", "images", "inside", "latest", "media", "month", "monthly", "music", "name",
    "named", "old", "older", "path", "pdf", "pdfs", "photo", "photos", "picture",
    "pictures", "podcast", "podcasts", "recent", "recently", "screenshot", "screenshots",
    "script", "scripts", "settings", "source", "today", "video", "videos", "week",
    "weekly", "year", "yesterday", "zip",
    "архив", "архивы", "аудио", "видео", "внутри", "вчера", "документ", "документы",
    "изображение", "изображения", "имени", "имя", "картинка", "картинки", "код",
    "конфиг", "конфиги", "контент", "месяц", "музыка", "музыку", "названии", "настройка",
    "настройки", "недавние", "недавний", "недавно", "папка", "папки", "папку", "подкаст",
    "подкасты", "путь", "свежие", "свежий", "сегодня", "скриншот", "скриншоты", "скрины",
    "скрипт", "скрипты", "содержимое", "содержимом", "старые", "старый", "фото",
    "фотки", "фотография", "фотографии", "год", "года", "году", "неделя",
    "архів", "архіви", "аудіо", "відео", "вміст", "всередині", "вчора", "документи",
    "зображення", "знімки", "конфіг", "конфіги", "місяць", "місяця", "музика",
    "налаштування", "нещодавні", "нещодавно", "подкасти", "скріншот", "скріншоти",
    "рік", "року", "сьогодні", "старі", "тека", "теки", "теку", "тиждень", "тижня",
}

# Longest first. Trimming one common Russian/Ukrainian case or number ending
# lets "бюджетом" find "бюджет.pdf" and "отпуска" find "отпуск/"; a stem keeps
# at least four letters, and quoted phrases are never trimmed.
_CYRILLIC_ENDINGS = tuple(sorted({
    "иями", "ями", "ами", "ого", "его", "ому", "ему", "ыми", "ими", "ові", "еві",
    "ях", "ах", "ов", "ев", "ів", "ам", "ям", "ом", "ем", "ой", "ей", "ою", "ею",
    "ую", "юю", "ая", "яя", "ые", "ие", "ый", "ий", "ої", "ій",
    "а", "я", "у", "ю", "ы", "и", "і", "ї", "е", "о", "ь", "й",
}, key=len, reverse=True))
_STEM_MIN = 4

_KIND_PATTERNS = (
    ("config", (
        r"\bconfig(?:uration|s)?\b", r"\bsettings?\b", r"\bконфиг(?:и|ов|ами)?\b",
        r"\bнастрой(?:ка|ки|ках|ками)\b", r"\bконфіг\w*\b", r"\bналаштуван\w*\b",
        r"\bdotfiles?\b", r"\.(?:ini|toml|ya?ml|conf|env)\b",
    )),
    ("video", (
        r"\bvideos?\b", r"\bmovies?\b", r"\bscreen\s+recordings?\b",
        r"\b(?:видео|відео)\b", r"\bфил[ьл]м\w*\b", r"\bфільм\w*\b",
        r"\bзапис\w*\s+(?:экрана|екрану)\b", r"\.(?:mp4|mkv|webm|mov|avi)\b",
    )),
    ("image", (
        r"\bimages?\b", r"\bpictures?\b", r"\bphotos?\b", r"\bscreenshots?\b",
        r"\b(?:фото|фотографии|изображения?)\b", r"\bфотк\w*\b", r"\bфотограф\w*\b",
        r"\bкартинк\w*\b", r"\bскрин\w*\b", r"\bскріншот\w*\b",
        r"\bзображен\w*\b", r"\bзнімк\w*\b", r"\.(?:png|jpe?g|gif|webp|svg)\b",
    )),
    ("audio", (
        r"\baudio\b", r"\bmusic\b", r"\bpodcasts?\b", r"\bsongs?\b",
        r"\b(?:аудио|аудіо)\b", r"\bмузы?к\w*\b", r"\bмузик\w*\b",
        r"\bподкаст\w*\b", r"\bпесн\w*\b", r"\bпісн\w*\b",
        r"\.(?:mp3|flac|wav|ogg|m4a)\b",
    )),
    ("archive", (
        r"\barchives?\b", r"\bzips?\b", r"\bархив(?:ы|ов)?\b", r"\bархів\w*\b",
        r"\.(?:zip|tar|gz|bz2|xz|7z|rar)\b",
    )),
    ("code", (
        r"\bcode\b", r"\bsource\b", r"\bscripts?\b", r"\bкод\b", r"\bскрипт(?:ы|ов)?\b",
        r"\.(?:py|js|ts|tsx|jsx|rs|go|java|c|cc|cpp|h|hpp|sh|lua|qml)\b",
    )),
    ("document", (
        r"\bdocuments?\b", r"\bspreadsheet\b", r"\bpdfs?\b",
        r"\bдокумент\w*\b", r"\bтаблиц\w*\b", r"\bpresentations?\b",
        r"\bпрезентаци\w*\b", r"\bпрезентаці\w*\b",
        r"\.(?:pdf|docx?|odt|rtf|txt|md|csv|xlsx?|ods|pptx?)\b",
    )),
)


def _normal_text(value: str) -> str:
    return " ".join(str(value or "").strip().split())


def _hint(value: str = "any", confidence: float = 1.0, source: str = "rule") -> dict[str, Any]:
    amount = float(confidence)
    if not math.isfinite(amount):
        amount = 0.0
    return {
        "value": value,
        "confidence": round(max(0.0, min(1.0, amount)), 4),
        "source": source,
    }


def rule_hints(query: str) -> dict[str, dict[str, Any]]:
    """Return explicit bilingual hints without making any probabilistic guesses."""
    folded = f" {_normal_text(query).casefold()} "
    hints = {key: _hint() for key in SMART_HINT_VALUES}

    if re.search(
        r"\b(?:folders?|director(?:y|ies)|папк[аиуе]|тек[аиуі]|каталог\w*|директори\w*)\b",
        folded,
    ):
        hints["target"] = _hint("folder")
    elif re.search(r"\b(?:files?|файл(?:а|е|ы|и|ів|у)?)\b", folded):
        hints["target"] = _hint("file")

    for kind, patterns in _KIND_PATTERNS:
        if any(re.search(pattern, folded) for pattern in patterns):
            hints["kind"] = _hint(kind)
            break

    if re.search(
        r"\b(?:content|contents|inside|contains?|содержим\w*|внутри|контент|вміст\w*"
        r"|всередині)\b",
        folded,
    ):
        hints["location"] = _hint("content")
    elif re.search(r"\b(?:path|пути|путь|шлях\w*)\b", folded):
        hints["location"] = _hint("path")
    elif re.search(r"\b(?:name|named|called|имя|имени|назв\w*)\b", folded):
        hints["location"] = _hint("name")

    time_patterns = (
        ("yesterday", (r"\byesterday\b", r"\bвчера\b", r"\bвчора\b")),
        ("today", (r"\btoday\b", r"\bсегодня\b", r"\bсьогодні\b")),
        ("last-week", (
            r"\blast\s+week\b", r"\bпрошл\w*\s+недел\w*\b", r"\bминул\w*\s+тиж\w*\b",
        )),
        ("this-week", (
            r"\bthis\s+week\b", r"\bэт\w*\s+недел\w*\b", r"\bц(?:ього|ей|ьому)\s+тиж\w*\b",
        )),
        ("last-month", (
            r"\blast\s+month\b", r"\bпрошл\w*\s+месяц\w*\b", r"\bминул\w*\s+місяц\w*\b",
        )),
        ("this-month", (
            r"\bthis\s+month\b", r"\bэт\w*\s+месяц\w*\b", r"\bц(?:ього|ей|ьому)\s+місяц\w*\b",
        )),
        # Whole adjective forms only: a bare "стар" prefix would also match
        # "стартапы" and turn a topic word into a date filter.
        ("older", (
            r"\bold(?:er)?\b", r"\blast\s+year\b", r"\bпрошл\w*\s+год\w*\b",
            r"\bминул\w*\s+р(?:ік|оку)\b",
            r"\bстар(?:ый|ая|ое|ые|ых|ого|ой|ую|ым|ыми|ий|а|е|і|их|ої|ими)\b",
        )),
    )
    for value, patterns in time_patterns:
        if any(re.search(pattern, folded) for pattern in patterns):
            hints["time"] = _hint(value)
            break
    return hints


def _inflection_stem(term: str) -> str:
    if not term.isalpha():
        return term
    folded = term.casefold()
    if re.fullmatch(r"[а-яёіїєґ]+", folded):
        for ending in _CYRILLIC_ENDINGS:
            if folded.endswith(ending) and len(term) - len(ending) >= _STEM_MIN:
                return term[:-len(ending)]
        return term
    # English plurals only: "invoices" must still find "invoice.pdf".
    if (re.fullmatch(r"[a-z]+", folded) and len(term) > _STEM_MIN
            and folded.endswith("s") and not folded.endswith(("ss", "us", "is"))):
        return term[:-1]
    return term


def extract_terms(query: str) -> list[str]:
    """Extract bounded lexical terms while preserving explicit quoted phrases."""
    normalized = _normal_text(query)
    if len(normalized) > SMART_QUERY_LIMIT:
        normalized = normalized[:SMART_QUERY_LIMIT]
    terms: list[str] = []
    spans: list[tuple[int, int]] = []
    for match in re.finditer(r'"([^"\n]+)"|\'([^\'\n]+)\'', normalized):
        value = _normal_text(match.group(1) or match.group(2) or "")
        if value:
            terms.append(value[:SMART_TERM_LENGTH_LIMIT])
        spans.append(match.span())
    remainder = list(normalized)
    for start, end in spans:
        remainder[start:end] = " " * (end - start)
    for raw in re.findall(r"[^\W_][\w.+#@-]*", "".join(remainder), flags=re.UNICODE):
        folded = raw.casefold().strip(".-_@")
        if not folded or folded in _SEARCH_WORDS or folded in _CONTROL_WORDS:
            continue
        if len(folded) == 1 and not folded.isdigit():
            continue
        terms.append(_inflection_stem(raw)[:SMART_TERM_LENGTH_LIMIT])
    unique: list[str] = []
    seen: set[str] = set()
    for term in terms:
        key = term.casefold()
        if key in seen:
            continue
        seen.add(key)
        unique.append(term)
        if len(unique) >= SMART_TERM_LIMIT:
            break
    return unique


def fallback_plan(query: str, request_id: int | None = None) -> dict[str, Any]:
    normalized = _normal_text(query)
    if len(normalized) > SMART_QUERY_LIMIT:
        normalized = normalized[:SMART_QUERY_LIMIT]
    plan: dict[str, Any] = {
        "version": SMART_PLAN_VERSION,
        "terms": extract_terms(normalized),
        "hints": rule_hints(normalized),
    }
    if request_id is not None:
        plan["requestId"] = int(request_id)
    return plan


def merge_laya_answers(plan: dict[str, Any], answers: Any) -> dict[str, Any]:
    """Fill rule-free hint slots from an untrusted Laya answer mapping."""
    merged = validate_plan(plan)
    if not isinstance(answers, dict):
        return merged
    for field, allowed in SMART_HINT_VALUES.items():
        current = merged["hints"][field]
        if current["value"] != "any":
            continue
        answer = answers.get(field)
        if not isinstance(answer, dict):
            continue
        choice = str(answer.get("choice", ""))
        if choice not in allowed:
            continue
        try:
            confidence = float(answer.get("confidence", 0.0))
        except (TypeError, ValueError):
            confidence = 0.0
        if not math.isfinite(confidence) or confidence < SMART_CONFIDENCE_MIN:
            continue
        merged["hints"][field] = _hint(choice, confidence, "laya")
    return merged


def validate_plan(plan: Any) -> dict[str, Any]:
    """Return a normalized plan or reject malformed/oversized untrusted input."""
    if not isinstance(plan, dict) or plan.get("version") != SMART_PLAN_VERSION:
        raise SmartPlanError("unsupported smart-search plan")
    raw_terms = plan.get("terms", [])
    if not isinstance(raw_terms, list) or len(raw_terms) > SMART_TERM_LIMIT:
        raise SmartPlanError("smart-search terms are invalid")
    terms: list[str] = []
    for raw in raw_terms:
        if not isinstance(raw, str):
            raise SmartPlanError("smart-search term must be text")
        value = _normal_text(raw)
        if not value or len(value) > SMART_TERM_LENGTH_LIMIT or "\x00" in value:
            raise SmartPlanError("smart-search term has an invalid value")
        terms.append(value)

    raw_hints = plan.get("hints", {})
    if not isinstance(raw_hints, dict):
        raise SmartPlanError("smart-search hints are invalid")
    hints: dict[str, dict[str, Any]] = {}
    for field, allowed in SMART_HINT_VALUES.items():
        raw = raw_hints.get(field, {"value": "any", "confidence": 0.0, "source": "rule"})
        if not isinstance(raw, dict):
            raise SmartPlanError(f"smart-search {field} hint is invalid")
        value = raw.get("value", "any")
        source = raw.get("source", "rule")
        if value not in allowed or source not in {"rule", "laya"}:
            raise SmartPlanError(f"smart-search {field} hint is unsupported")
        try:
            confidence = float(raw.get("confidence", 0.0))
        except (TypeError, ValueError) as exc:
            raise SmartPlanError(f"smart-search {field} confidence is invalid") from exc
        if not 0.0 <= confidence <= 1.0:
            raise SmartPlanError(f"smart-search {field} confidence is out of range")
        hints[field] = _hint(str(value), confidence, str(source))
    normalized: dict[str, Any] = {
        "version": SMART_PLAN_VERSION,
        "terms": terms,
        "hints": hints,
    }
    request_id = plan.get("requestId")
    if isinstance(request_id, int) and not isinstance(request_id, bool) and request_id >= 0:
        normalized["requestId"] = request_id
    model = plan.get("model")
    if isinstance(model, str) and 0 < len(model) <= 64:
        normalized["model"] = model
    device = plan.get("device")
    if isinstance(device, str) and 0 < len(device) <= 32:
        normalized["device"] = device
    latency = plan.get("latencyMs")
    if isinstance(latency, (int, float)) and not isinstance(latency, bool):
        latency_value = float(latency)
        if math.isfinite(latency_value):
            normalized["latencyMs"] = max(0, min(60000, round(latency_value)))
    return normalized


def questions() -> dict[str, dict[str, Any]]:
    """The fixed low-cardinality decision schema evaluated in one forward pass."""
    return {
        "target": {
            "type": "choice",
            "instructions": "Does the user ask for files, folders, or either?",
            "criteria": {
                "any": "No explicit preference, or both files and folders",
                "file": "Regular files rather than directories",
                "folder": "Directories or folders rather than regular files",
            },
        },
        "kind": {
            "type": "choice",
            "instructions": "Which broad file kind does the search request specify?",
            "criteria": {
                "any": "No broad file kind is specified",
                "document": "Documents, PDFs, notes, office files, or spreadsheets",
                "code": "Source code or scripts",
                "config": "Configuration, settings, or environment files",
                "image": "Images, photos, or graphics",
                "audio": "Audio, speech, or music",
                "video": "Video or movies",
                "archive": "Compressed files or archives",
            },
        },
        "location": {
            "type": "choice",
            "instructions": "Where does the user expect the search text to match?",
            "criteria": {
                "any": "No preference between name, path, and contents",
                "name": "The file or folder name",
                "path": "The relative filesystem path",
                "content": "Text inside a file",
            },
        },
        "time": {
            "type": "choice",
            "instructions": "Which modification-time window does the request specify?",
            "criteria": {
                "any": "No modification-time condition",
                "today": "Modified today",
                "yesterday": "Modified yesterday",
                "this-week": "Modified during the current calendar week",
                "last-week": "Modified during the previous calendar week",
                "this-month": "Modified during the current calendar month",
                "last-month": "Modified during the previous calendar month",
                "older": "Older than the start of the previous calendar month",
            },
        },
    }
