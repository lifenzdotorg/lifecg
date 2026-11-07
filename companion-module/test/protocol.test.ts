import { describe, expect, it } from 'vitest'
import {
	CUSTOM_CHOICE_ID,
	EMPTY_STATE,
	currentMatchesText,
	normaliseState,
	parseServerMessage,
	recentSignature,
	showTitleChoices,
	stateToVariables,
	variableDefinitions,
	type LifeCGState,
} from '../src/protocol.js'

const luke = { id: 'a1b2c3d4', title: 'Ps Luke de Jong', designation: 'Lead Pastor' }
const anna = { id: 'deadbeef', title: 'Anna Smith', designation: '' }

const sample: LifeCGState = {
	protocol: 1,
	onAir: true,
	current: luke,
	last: luke,
	recent: [
		{ ...luke, lastUsed: '2026-11-08T09:30:00Z' },
		{ ...anna, lastUsed: '2026-11-08T09:00:00Z' },
	],
}

describe('state -> variables', () => {
	it('maps the on-air state', () => {
		const v = stateToVariables(sample)
		expect(v.on_air).toBe(true)
		expect(v.title).toBe('Ps Luke de Jong')
		expect(v.designation).toBe('Lead Pastor')
		expect(v.last_title).toBe('Ps Luke de Jong')
		expect(v.recent_count).toBe(2)
		expect(v.recent_1_label).toBe('Ps Luke de Jong\nLead Pastor')
		expect(v.recent_2_title).toBe('Anna Smith')
		expect(v.recent_2_designation).toBe('')
		expect(v.recent_2_label).toBe('Anna Smith')
		expect(v.recent_3_title).toBe('')
		expect(v.recent_20_label).toBe('')
	})

	it('blanks current title when off air but keeps last', () => {
		const v = stateToVariables({ ...sample, onAir: false, current: null })
		expect(v.on_air).toBe(false)
		expect(v.title).toBe('')
		expect(v.designation).toBe('')
		expect(v.last_title).toBe('Ps Luke de Jong')
		expect(v.last_designation).toBe('Lead Pastor')
	})

	it('defines every variable it sets', () => {
		const defs = variableDefinitions()
		expect(Object.keys(stateToVariables(sample)).sort()).toEqual(Object.keys(defs).sort())
		expect(Object.keys(defs)).toHaveLength(6 + 20 * 3)
	})
})

describe('dropdown choices', () => {
	it('puts the custom choice first then recent entries keyed by id', () => {
		expect(showTitleChoices(sample)).toEqual([
			{ id: CUSTOM_CHOICE_ID, label: '— Type a new title —' },
			{ id: 'a1b2c3d4', label: 'Ps Luke de Jong — Lead Pastor' },
			{ id: 'deadbeef', label: 'Anna Smith' },
		])
		expect(showTitleChoices(EMPTY_STATE)).toHaveLength(1)
	})

	it('signature changes only when the recent list changes', () => {
		const a = recentSignature(sample)
		expect(recentSignature({ ...sample, onAir: false, current: null })).toBe(a)
		expect(recentSignature({ ...sample, recent: sample.recent.slice(1) })).not.toBe(a)
	})
})

describe('parsing', () => {
	it('parses and normalises state messages defensively', () => {
		const msg = parseServerMessage(
			JSON.stringify({ type: 'state', protocol: 1, onAir: false, current: null, last: null, recent: [{ id: 'x', title: 'T' }] })
		)
		expect(msg).toEqual({
			type: 'state',
			protocol: 1,
			onAir: false,
			current: null,
			last: null,
			recent: [{ id: 'x', title: 'T', designation: '' }],
		})
	})

	it('caps recent at 20', () => {
		const recent = Array.from({ length: 25 }, (_, i) => ({ id: `id${i}`, title: `T${i}`, designation: '' }))
		expect(normaliseState({ recent }).recent).toHaveLength(20)
	})

	it('handles pong, error and garbage', () => {
		expect(parseServerMessage('{"type":"pong"}')).toEqual({ type: 'pong' })
		expect(parseServerMessage('{"type":"error","message":"nope"}')).toEqual({ type: 'error', message: 'nope' })
		expect(parseServerMessage('not json')).toBeNull()
		expect(parseServerMessage('{"type":"wat"}')).toBeNull()
	})
})

describe('text matching for Title is On Air', () => {
	it('matches case-insensitively, designation optional', () => {
		expect(currentMatchesText(sample, ' ps luke de jong ', '')).toBe(true)
		expect(currentMatchesText(sample, 'Ps Luke de Jong', 'lead pastor')).toBe(true)
		expect(currentMatchesText(sample, 'Ps Luke de Jong', 'Worship')).toBe(false)
		expect(currentMatchesText(sample, '', '')).toBe(false)
		expect(currentMatchesText({ ...sample, onAir: false, current: null }, 'Ps Luke de Jong', '')).toBe(false)
	})
})
