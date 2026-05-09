/**
 * Validators — shared validation logic for room/game inputs.
 * Extracted from roomController.js to reduce controller size.
 */

// Import shared constants from api-contracts
const {
    VALID_CHARACTERS: CHARACTERS_ARRAY,
    VALID_SKILLS: SKILLS_ARRAY,
    VALID_PASSIVES: PASSIVES_ARRAY,
    VALID_PHASES: PHASES_ARRAY
} = require('../../shared/api-contracts');

// Convert to Sets for O(1) lookup
const VALID_CHARACTERS = new Set(CHARACTERS_ARRAY);
const VALID_SKILLS = new Set(SKILLS_ARRAY);
const VALID_PASSIVES = new Set(PASSIVES_ARRAY);
const VALID_PHASES = new Set(PHASES_ARRAY);

/**
 * Validate character selection
 * @param {string} character - Character name
 * @returns {{ valid: boolean, error?: string }}
 */
function validateCharacter(character) {
    if (character === undefined) return { valid: true };
    if (!VALID_CHARACTERS.has(character)) {
        return { valid: false, error: 'Invalid character' };
    }
    return { valid: true };
}

/**
 * Validate skills array
 * @param {any} skills - Skills array
 * @returns {{ valid: boolean, error?: string }}
 */
function validateSkills(skills) {
    if (skills === undefined) return { valid: true };
    if (!Array.isArray(skills) || skills.length > 2) {
        return { valid: false, error: 'skills must be an array of at most 2 entries' };
    }
    for (const s of skills) {
        if (!VALID_SKILLS.has(s)) {
            return { valid: false, error: `Invalid skill: ${s}` };
        }
    }
    const unique = new Set(skills);
    if (unique.size !== skills.length) {
        return { valid: false, error: 'Duplicate skills are not allowed' };
    }
    return { valid: true };
}

/**
 * Validate passive selection
 * @param {string} passive - Passive name
 * @returns {{ valid: boolean, error?: string }}
 */
function validatePassive(passive) {
    if (passive === undefined) return { valid: true };
    if (passive !== '' && !VALID_PASSIVES.has(passive)) {
        return { valid: false, error: 'Invalid passive' };
    }
    return { valid: true };
}

/**
 * Validate phase value
 * @param {string} phase - Phase name
 * @returns {{ valid: boolean, error?: string }}
 */
function validatePhase(phase) {
    if (!VALID_PHASES.has(phase)) {
        return { valid: false, error: 'Invalid phase' };
    }
    return { valid: true };
}

/**
 * Validate chosen skill is in player's loadout
 * @param {string} skill - Skill name
 * @param {string[]} loadout - Player's selected skills
 * @returns {{ valid: boolean, error?: string }}
 */
function validateChosenSkill(skill, loadout) {
    if (!skill || skill === '') return { valid: true };
    if (!VALID_SKILLS.has(skill)) {
        return { valid: false, error: 'Invalid chosen_skill' };
    }
    if (!Array.isArray(loadout) || !loadout.includes(skill)) {
        return { valid: false, error: 'chosen_skill is not in player loadout' };
    }
    return { valid: true };
}

/**
 * Validate all selections at once
 * @param {object} selections - { character?, skills?, passive? }
 * @returns {{ valid: boolean, error?: string }}
 */
function validateSelections(selections) {
    const { character, skills, passive } = selections;
    
    const charResult = validateCharacter(character);
    if (!charResult.valid) return charResult;
    
    const skillsResult = validateSkills(skills);
    if (!skillsResult.valid) return skillsResult;
    
    const passiveResult = validatePassive(passive);
    if (!passiveResult.valid) return passiveResult;
    
    return { valid: true };
}

/**
 * Check if request body user_id matches authenticated user
 * @param {object} req - Express request with user and body
 * @param {object} res - Express response (used to send error)
 * @returns {boolean} - true if valid, false if error sent
 */
function assertBodyUserMatchesActor(req, res) {
    const actorId = req.user && req.user.id;
    if (req.body && req.body.user_id !== undefined && String(req.body.user_id) !== String(actorId)) {
        res.status(403).json({ message: 'user_id does not match authenticated user' });
        return false;
    }
    return true;
}

/**
 * Get actor ID from request
 * @param {object} req - Express request
 * @returns {number|string|null}
 */
function getActorId(req) {
    return req.user && req.user.id;
}

module.exports = {
    VALID_CHARACTERS,
    VALID_SKILLS,
    VALID_PASSIVES,
    VALID_PHASES,
    validateCharacter,
    validateSkills,
    validatePassive,
    validatePhase,
    validateChosenSkill,
    validateSelections,
    assertBodyUserMatchesActor,
    getActorId
};
