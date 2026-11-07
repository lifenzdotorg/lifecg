import type { CompanionPresetDefinitions, CompanionPresetSection } from '@companion-module/base'
import type { ModuleSchema } from './main.js'

const BLACK = 0x000000
const WHITE = 0xffffff
const RED = 0xcc0000
const DARK_GREY = 0x333333

/** Number of "Recent N" preset buttons. */
export const RECENT_PRESET_COUNT = 10

/**
 * Variable references in preset text use the module id as the connection label.
 * Companion rewrites `$(<anything>:var)` to `$(<actual connection label>:var)`
 * when the preset is placed on a button (see companion/lib/Instance/Definitions.ts,
 * replaceAllVariables), so this works whatever the connection is called.
 */
const V = (name: string) => `$(lifenz-lifecg:${name})`

export function buildPresets(): {
	structure: CompanionPresetSection<ModuleSchema>[]
	presets: CompanionPresetDefinitions<ModuleSchema>
} {
	const presets: CompanionPresetDefinitions<ModuleSchema> = {}

	presets['hide'] = {
		type: 'simple',
		name: 'Hide Title',
		style: { text: 'HIDE', size: '24', color: WHITE, bgcolor: BLACK },
		steps: [{ down: [{ actionId: 'hide_title', options: {} }], up: [] }],
		feedbacks: [],
	}

	presets['toggle'] = {
		type: 'simple',
		name: 'Toggle Title (red when on air)',
		style: { text: 'LOWER\\nTHIRD', size: '18', color: WHITE, bgcolor: BLACK },
		steps: [{ down: [{ actionId: 'toggle_title', options: {} }], up: [] }],
		feedbacks: [{ feedbackId: 'on_air', options: {}, style: { bgcolor: RED, color: WHITE } }],
	}

	presets['on_air_title'] = {
		type: 'simple',
		name: 'Current title (display, toggles on press)',
		style: { text: `${V('title')}`, size: 'auto', color: WHITE, bgcolor: DARK_GREY },
		steps: [{ down: [{ actionId: 'toggle_title', options: {} }], up: [] }],
		feedbacks: [{ feedbackId: 'on_air', options: {}, style: { bgcolor: RED, color: WHITE } }],
	}

	const recentIds: string[] = []
	for (let n = 1; n <= RECENT_PRESET_COUNT; n++) {
		const id = `recent_${n}`
		recentIds.push(id)
		presets[id] = {
			type: 'simple',
			name: `Recent ${n}`,
			style: { text: V(`recent_${n}_label`), size: 'auto', color: WHITE, bgcolor: DARK_GREY },
			previewStyle: { text: `Recent ${n}` },
			steps: [{ down: [{ actionId: 'show_recent_position', options: { position: n, autoClear: false } }], up: [] }],
			feedbacks: [],
		}
	}

	const structure: CompanionPresetSection<ModuleSchema>[] = [
		{
			id: 'control',
			name: 'Control',
			definitions: [
				{
					id: 'control_main',
					type: 'simple',
					name: 'Show / Hide',
					presets: ['toggle', 'hide', 'on_air_title'],
				},
			],
		},
		{
			id: 'recent',
			name: 'Recent Titles',
			description: 'Buttons showing the Nth most recent title. Labels update live from LifeCG.app.',
			definitions: [
				{
					id: 'recent_positions',
					type: 'simple',
					name: 'Recent 1–10',
					presets: recentIds,
				},
			],
		},
	]

	return { structure, presets }
}
