import type { CompanionFeedbackDefinitions } from '@companion-module/base'
import { CUSTOM_CHOICE_ID, currentMatchesText, recentChoices, type LowerThirdsState } from './protocol.js'

export type FeedbacksSchema = {
	on_air: { type: 'boolean'; options: Record<string, never> }
	title_on_air: { type: 'boolean'; options: { recent: string; title: string; designation: string } }
}

const RED = 0xcc0000
const WHITE = 0xffffff

const str = (v: unknown): string => (v === undefined || v === null ? '' : String(v))

export function buildFeedbackDefinitions(getState: () => LowerThirdsState): CompanionFeedbackDefinitions<FeedbacksSchema> {
	const state = getState()
	const visibleWhenText = `$(options:recent) == '${CUSTOM_CHOICE_ID}'`

	return {
		on_air: {
			type: 'boolean',
			name: 'On Air',
			description: 'True while any title is on air.',
			defaultStyle: { bgcolor: RED, color: WHITE },
			options: [],
			callback: () => getState().onAir,
		},
		title_on_air: {
			type: 'boolean',
			name: 'Title is On Air',
			description: 'True while a specific title is on air.',
			defaultStyle: { bgcolor: RED, color: WHITE },
			options: [
				{
					id: 'recent',
					type: 'dropdown',
					label: 'Title',
					choices: [{ id: CUSTOM_CHOICE_ID, label: '— Match by text —' }, ...recentChoices(state)],
					default: CUSTOM_CHOICE_ID,
					disableAutoExpression: true,
					minChoicesForSearch: 8,
				},
				{
					id: 'title',
					type: 'textinput',
					label: 'Title text (case-insensitive)',
					default: '',
					useVariables: true,
					isVisibleExpression: visibleWhenText,
				},
				{
					id: 'designation',
					type: 'textinput',
					label: 'Designation (optional; blank matches any)',
					default: '',
					useVariables: true,
					isVisibleExpression: visibleWhenText,
				},
			],
			callback: (fb) => {
				const s = getState()
				const choice = str(fb.options.recent) || CUSTOM_CHOICE_ID
				if (choice === CUSTOM_CHOICE_ID) {
					return currentMatchesText(s, str(fb.options.title), str(fb.options.designation))
				}
				return s.onAir && s.current?.id === choice
			},
		},
	}
}
