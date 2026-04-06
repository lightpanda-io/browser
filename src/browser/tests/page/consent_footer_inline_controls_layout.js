test("consent footer inline controls keep select and footer links below the actions row", async () => {
  const footer = document.getElementById("footer");
  const languageForm = document.getElementById("language-form");
  const languageSelect = document.getElementById("language-select");
  const privacy = document.getElementById("privacy");
  const terms = document.getElementById("terms");
  const actions = document.getElementById("actions");

  const footerRect = footer.getBoundingClientRect();
  const formRect = languageForm.getBoundingClientRect();
  const selectRect = languageSelect.getBoundingClientRect();
  const privacyRect = privacy.getBoundingClientRect();
  const termsRect = terms.getBoundingClientRect();
  const actionsRect = actions.getBoundingClientRect();

  expect(actionsRect.y).toBeGreaterThan(0);
  expect(footerRect.y).toBeGreaterThan(actionsRect.bottom + 12);
  expect(formRect.y).toBeGreaterThan(actionsRect.bottom + 12);
  expect(selectRect.y).toBeGreaterThan(actionsRect.bottom + 12);
  expect(privacyRect.y).toBeGreaterThan(actionsRect.bottom + 12);
  expect(termsRect.y).toBeGreaterThan(actionsRect.bottom + 12);

  expect(selectRect.width).toBeGreaterThanOrEqual(120);
  expect(privacyRect.x).toBeGreaterThan(selectRect.right + 12);
  expect(termsRect.x).toBeGreaterThan(privacyRect.right + 12);
});
