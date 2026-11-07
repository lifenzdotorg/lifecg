/**
 * Types and pure helpers for the LifeCG control protocol v1.
 * See docs/PROTOCOL.md in the repository. This file must not import
 * @companion-module/base at runtime so it can be unit tested in isolation.
 */

export const PROTOCOL_VERSION = 1
export const MAX_RECENT = 20
export const CUSTOM_CHOICE_ID = '__custom__'

export interface TitleEntry {
	id: string
	title: string
	designation: string
}

export interface RecentEntry extends TitleEntry {
	lastUsed?: string
}

export interface LifeCGState {
	protocol: number
	onAir: boolean
	current: TitleEntry | null
	last: TitleEntry | null
	recent: RecentEntry[]
}

export type ClientMessage =
	| { type: 'hello'; client: string; name: string; protocol: number }
	| { type: 'show'; title: string; designation?: string }
	| { type: 'showRecent'; id: string }
	| { type: 'showRecent'; index: number }
	| { type: 'hide' }
	| { type: 'toggle' }
	| { type: 'removeRecent'; id: string }
	| { type: 'clearRecent' }
	| { type: 'ping' }

export type ServerMessage =
	| ({ type: 'state' } & LifeCGState)
	| { type: 'pong' }
	| { type: 'error'; message: string }

export const EMPTY_STATE: LifeCGState = {
	protocol: PROTOCOL_VERSION,
	onAir: false,
	current: null,
	last: null,
	recent: [],
}

function asString(v: unknown): string {
	return typeof v === 'string' ? v : v === undefined || v === null ? '' : String(v)
}

function normaliseEntry(raw: unknown): TitleEntry | null {
	if (!raw || typeof raw !== 'object') return null
	const r = raw as Record<string, unknown>
	const id = asString(r.id)
	const title = asString(r.title)
	if (!id && !title) return null
	return { id, title, designation: asString(r.designation) }
}

/** Defensive normalisation of an incoming `state` message. */
export function normaliseState(raw: Record<string, unknown>): LifeCGState {
	const recentRaw = Array.isArray(raw.recent) ? raw.recent : []
	const recent: RecentEntry[] = []
	for (const item of recentRaw) {
		const e = normaliseEntry(item)
		if (!e) continue
		const lastUsed = (item as Record<string, unknown>).lastUsed
		recent.push(typeof lastUsed === 'string' ? { ...e, lastUsed } : e)
		if (recent.length >= MAX_RECENT) break
	}
	const current = normaliseEntry(raw.current)
	return {
		protocol: typeof raw.protocol === 'number' ? raw.protocol : PROTOCOL_VERSION,
		onAir: raw.onAir === true,
		current,
		last: normaliseEntry(raw.last),
		recent,
	}
}

/** Parse one inbound text frame. Returns null for anything unrecognised. */
export function parseServerMessage(data: string): ServerMessage | null {
	let obj: unknown
	try {
		obj = JSON.parse(data)
	} catch {
		return null
	}
	if (!obj || typeof obj !== 'object') return null
	const msg = obj as Record<string, unknown>
	switch (msg.type) {
		case 'state':
			return { type: 'state', ...normaliseState(msg) }
		case 'pong':
			return { type: 'pong' }
		case 'error':
			return { type: 'error', message: asString(msg.message) || 'Unknown error' }
		default:
			return null
	}
}

/** Dropdown label: "Title — Designation", or just "Title". */
export function entryLabel(e: TitleEntry): string {
	return e.designation ? `${e.title} — ${e.designation}` : e.title
}

/** Button label: "Title\nDesignation", or just "Title". */
export function entryButtonLabel(e: TitleEntry): string {
	return e.designation ? `${e.title}\n${e.designation}` : e.title
}

export interface Choice {
	id: string
	label: string
}

export function recentChoices(state: LifeCGState): Choice[] {
	return state.recent.map((e) => ({ id: e.id, label: entryLabel(e) }))
}

/** Choices for the "Show Title" dropdown: custom first, then Recent. */
export function showTitleChoices(state: LifeCGState): Choice[] {
	return [{ id: CUSTOM_CHOICE_ID, label: '— Type a new title —' }, ...recentChoices(state)]
}

/** A cheap signature so we only rebuild action/feedback definitions when the dropdowns would change. */
export function recentSignature(state: LifeCGState): string {
	return JSON.stringify(state.recent.map((e) => [e.id, e.title, e.designation]))
}

export function findRecent(state: LifeCGState, id: string): RecentEntry | undefined {
	return state.recent.find((e) => e.id === id)
}

export type VariableValues = Record<string, string | number | boolean>

/** Map a state object to Companion variable values. */
export function stateToVariables(state: LifeCGState): VariableValues {
	const cur = state.onAir ? state.current : null
	const values: VariableValues = {
		on_air: state.onAir,
		title: cur?.title ?? '',
		designation: cur?.designation ?? '',
		last_title: state.last?.title ?? '',
		last_designation: state.last?.designation ?? '',
		recent_count: state.recent.length,
	}
	for (let i = 0; i < MAX_RECENT; i++) {
		const e = state.recent[i]
		const n = i + 1
		values[`recent_${n}_title`] = e?.title ?? ''
		values[`recent_${n}_designation`] = e?.designation ?? ''
		values[`recent_${n}_label`] = e ? entryButtonLabel(e) : ''
	}
	return values
}

export function variableDefinitions(): Record<string, { name: string }> {
	const defs: Record<string, { name: string }> = {
		on_air: { name: 'A title is on air (true/false)' },
		title: { name: 'Current title (empty when off air)' },
		designation: { name: 'Current designation (empty when off air)' },
		last_title: { name: 'Last shown title' },
		last_designation: { name: 'Last shown designation' },
		recent_count: { name: 'Number of recent titles' },
	}
	for (let n = 1; n <= MAX_RECENT; n++) {
		defs[`recent_${n}_title`] = { name: `Recent ${n}: title` }
		defs[`recent_${n}_designation`] = { name: `Recent ${n}: designation` }
		defs[`recent_${n}_label`] = { name: `Recent ${n}: button label (title + newline + designation)` }
	}
	return defs
}

/** Does the on-air title match a free-text title (and optional designation)? Case-insensitive, trimmed. */
export function currentMatchesText(state: LifeCGState, title: string, designation: string): boolean {
	if (!state.onAir || !state.current) return false
	const norm = (s: string) => s.trim().toLowerCase()
	const t = norm(title)
	if (!t) return false
	if (norm(state.current.title) !== t) return false
	const d = norm(designation)
	return d === '' || norm(state.current.designation) === d
}
