const calculateWPM = (charsTyped, timeSeconds) => {
  const words = charsTyped / 5;
  const minutes = timeSeconds / 60;
  return Math.round(words / minutes);
};

const calculateAccuracy = (totalChars, errors) => {
  if (totalChars === 0) return 0;
  return Math.round(((totalChars - errors) / totalChars) * 100);
};

const calculateDamage = (wpm, accuracy) => {
  // Example damage formula
  return Math.round(wpm * (accuracy / 100));
};

module.exports = {
  calculateWPM,
  calculateAccuracy,
  calculateDamage
};
