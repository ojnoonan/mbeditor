define("vs/basic-languages/typescript/typescript", ["vs/basic-languages/javascript/javascript"], function (javascript) {
  "use strict";

  return {
    conf: javascript.conf,
    language: Object.assign({}, javascript.language, {
      tokenPostfix: ".ts"
    })
  };
});