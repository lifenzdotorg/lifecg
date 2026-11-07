import type { CompanionActionDefinitions } from '@companion-module/base'
import {
	CUSTOM_CHOICE_ID,
	MAX_RECENT,
	findRecent,
	recentChoices,
	showTitleChoices,
	type ClientMessage,
	type LifeCGState,
} from './protocol.js'

export type ActionsSchema = {
	show_title: { options: { recent: string; title: string; designation: string } }
	show_recent_position: { options: { position: number } }
	hide_title: { options: Record<string, never> }
	toggle_title: { options: Record<string, never> }
	clear_recent: { options: Record<string, never> }
	remove_recent: { options: { id: string } }
}

/** What the action callbacks need from the module instance (kept small so it can be faked in tests). */
export interface ActionContext {
	getState(): LifeCGState
	send(msg: ClientMessage): boolean
	log(level: 'debug' | 'info' | 'warn' | 'error', message: string): void
}

const str = (v: unknown): string => (v === undefined || v === null ? '' : String(v))

/** Shown when the referenced field is a plain value, so `$(options:recent)` can be used in isVisibleExpression. */
const CUSTOM_VISIBLE = `$(options:recent) == '${CUSTOM_CHOICE_ID}'`

export function buildActionDefinitions(ctx: ActionContext): CompanionActionDefinitions<ActionsSchema> {
	const state = ctx.getState()
	const recent = recentChoices(state)

	return {
		show_title: {
			name: 'Show Title',
			description: 'Put a title on air: pick one from Recent Titles, or type a new one.',
			options: [
				{
					id: 'recent',
					type: 'dropdown',
					label: 'Recent Titles',
					choices: showTitleChoices(state),
					default: CUSTOM_CHOICE_ID,
					// Must be a plain value so the text fields' isVisibleExpression can reference it (API 2.0 rule)
					disableAutoExpression: true,
					minChoicesForSearch: 8,
				},
				{
					id: 'title',
					type: 'textinput',
					label: 'Title',
					default: '',
					useVariables: true,
					minLength: 1,
					isVisibleExpression: CUSTOM_VISIBLE,
				},
				{
					id: 'designation',
					type: 'textinput',
					label: 'Designation (optional)',
					default: '',
					useVariables: true,
					isVisibleExpression: CUSTOM_VISIBLE,
				},
			],
			callback: (action) => {
				const choice = str(action.options.recent) || CUSTOM_CHOICE_ID
				if (choice === CUSTOM_CHOICE_ID) {
					// With API 2.x Companion has already substituted $(variables) in `useVariables` fields
					const title = str(action.options.title).trim()
					const designation = str(action.options.designation).trim()
					if (!title) {
						ctx.log('warn', 'Show Title: title is empty, nothing sent')
						return
					}
					ctx.send({ type: 'show', title, designation })
					return
				}
				if (!findRecent(ctx.getState(), choice)) {
					ctx.log('warn', `Show Title: recent title "${choice}" is no longer in the Recent list; nothing sent`)
					return
				}
				ctx.send({ type: 'showRecent', id: choice })
			},
		},

		show_recent_position: {
			name: 'Show Recent Title by position',
			description: 'Show the Nth most recent title (1 = most recent).',
			options: [
				{
					id: 'position',
					type: 'number',
					label: 'Position (1 = most recent)',
					default: 1,
					min: 1,
					max: MAX_RECENT,
					asInteger: true,
					clampValues: true,
				},
			],
			callback: (action) => {
				const n = Math.round(Number(action.options.position))
				if (!Number.isFinite(n) || n < 1 || n > MAX_RECENT) {
					ctx.log('warn', `Show Recent: invalid position ${str(action.options.position)}`)
					return
				}
				const count = ctx.getState().recent.length
				if (n > count) {
					ctx.log('info', `Show Recent: position ${n} is empty (only ${count} recent titles)`)
					return
				}
				ctx.send({ type: 'showRecent', index: n - 1 })
			},
		},

		hide_title: {
			name: 'Hide Title',
			options: [],
			callback: () => {
				ctx.send({ type: 'hide' })
			},
		},

		toggle_title: {
			name: 'Toggle Title',
			description: 'Hide if on air, otherwise re-show the last title.',
			options: [],
			callback: () => {
				ctx.send({ type: 'toggle' })
			},
		},

		clear_recent: {
			name: 'Clear Recent Titles',
			description: 'Empties the shared Recent list in LifeCG.app (affects every Companion connected to it).',
			options: [],
			callback: () => {
				ctx.send({ type: 'clearRecent' })
			},
		},

		remove_recent: {
			name: 'Remove Recent Title',
			options: [
				{
					id: 'id',
					type: 'dropdown',
					label: 'Recent title',
					choices: recent,
					default: recent[0]?.id ?? '',
					disableAutoExpression: true,
					minChoicesForSearch: 8,
				},
			],
			callback: (action) => {
				const id = str(action.options.id)
				if (!id || !findRecent(ctx.getState(), id)) {
					ctx.log('warn', `Remove Recent Title: "${id}" is not in the Recent list; nothing sent`)
					return
				}
				ctx.send({ type: 'removeRecent', id })
			},
		},
	}
}
