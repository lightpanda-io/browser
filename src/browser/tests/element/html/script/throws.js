window.throws_ran = true;
throw new Error('external script that throws still fires load, not error');
