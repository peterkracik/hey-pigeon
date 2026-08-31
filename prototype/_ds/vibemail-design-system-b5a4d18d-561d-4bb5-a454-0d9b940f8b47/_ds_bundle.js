/* @ds-bundle: {"format":4,"namespace":"VibeMailDesignSystem_b5a4d1","components":[{"name":"Avatar","sourcePath":"components/core/Avatar.jsx"},{"name":"Card","sourcePath":"components/core/Card.jsx"},{"name":"Badge","sourcePath":"components/feedback/Badge.jsx"},{"name":"Tag","sourcePath":"components/feedback/Tag.jsx"},{"name":"Toast","sourcePath":"components/feedback/Toast.jsx"},{"name":"Tooltip","sourcePath":"components/feedback/Tooltip.jsx"},{"name":"Button","sourcePath":"components/forms/Button.jsx"},{"name":"Checkbox","sourcePath":"components/forms/Checkbox.jsx"},{"name":"IconButton","sourcePath":"components/forms/IconButton.jsx"},{"name":"Input","sourcePath":"components/forms/Input.jsx"},{"name":"Radio","sourcePath":"components/forms/Radio.jsx"},{"name":"Select","sourcePath":"components/forms/Select.jsx"},{"name":"Switch","sourcePath":"components/forms/Switch.jsx"},{"name":"Tabs","sourcePath":"components/navigation/Tabs.jsx"},{"name":"Dialog","sourcePath":"components/overlay/Dialog.jsx"}],"sourceHashes":{"components/core/Avatar.jsx":"2d646bfc2a11","components/core/Card.jsx":"89f9f71e5e66","components/feedback/Badge.jsx":"6df553d62171","components/feedback/Tag.jsx":"47e7157bbdbf","components/feedback/Toast.jsx":"c8d248a9e8b8","components/feedback/Tooltip.jsx":"0deb5df88d99","components/forms/Button.jsx":"4ad32e79ce5c","components/forms/Checkbox.jsx":"4dd3776915b6","components/forms/IconButton.jsx":"6de13427fdeb","components/forms/Input.jsx":"656582cea552","components/forms/Radio.jsx":"297a8d038182","components/forms/Select.jsx":"b87efb7a43ce","components/forms/Switch.jsx":"9e6974f82f33","components/navigation/Tabs.jsx":"f4b0e0e4fcc7","components/overlay/Dialog.jsx":"57794d86a72b","ui_kits/web/Composer.jsx":"5371e0ed0c93","ui_kits/web/InboxList.jsx":"0b98640ffde7","ui_kits/web/SearchOverlay.jsx":"d4692efbaead","ui_kits/web/Sidebar.jsx":"5869f445b129","ui_kits/web/ThreadView.jsx":"03bf8ba6dff6"},"inlinedExternals":[],"unexposedExports":[]} */

(() => {

const __ds_ns = (window.VibeMailDesignSystem_b5a4d1 = window.VibeMailDesignSystem_b5a4d1 || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// components/core/Avatar.jsx
try { (() => {
function Avatar({
  name = '',
  src,
  size = 36
}) {
  const initials = name.split(' ').filter(Boolean).slice(0, 2).map(n => n[0].toUpperCase()).join('');
  return src ? /*#__PURE__*/React.createElement("img", {
    src: src,
    alt: name,
    style: {
      width: size,
      height: size,
      borderRadius: '50%',
      objectFit: 'cover'
    }
  }) : /*#__PURE__*/React.createElement("span", {
    style: {
      width: size,
      height: size,
      borderRadius: '50%',
      background: 'var(--navy-200)',
      color: 'var(--navy-700)',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontFamily: 'var(--font-body)',
      fontWeight: 600,
      fontSize: size * 0.38
    }
  }, initials);
}
Object.assign(__ds_scope, { Avatar });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Avatar.jsx", error: String((e && e.message) || e) }); }

// components/core/Card.jsx
try { (() => {
function Card({
  children,
  padding = 20,
  flat = true
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: 'var(--surface-card)',
      border: flat ? 'none' : '1px solid var(--border-subtle)',
      borderRadius: flat ? 0 : 'var(--radius-lg)',
      padding
    }
  }, children);
}
Object.assign(__ds_scope, { Card });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Card.jsx", error: String((e && e.message) || e) }); }

// components/feedback/Badge.jsx
try { (() => {
const tones = {
  neutral: {
    background: 'var(--surface-sunken)',
    color: 'var(--text-secondary)'
  },
  coral: {
    background: 'var(--tag-coral-bg)',
    color: 'var(--tag-coral-fg)'
  },
  mint: {
    background: 'var(--tag-mint-bg)',
    color: 'var(--tag-mint-fg)'
  },
  lavender: {
    background: 'var(--tag-lavender-bg)',
    color: 'var(--tag-lavender-fg)'
  },
  sky: {
    background: 'var(--tag-sky-bg)',
    color: 'var(--tag-sky-fg)'
  },
  amber: {
    background: 'var(--tag-amber-bg)',
    color: 'var(--tag-amber-fg)'
  }
};
function Badge({
  children,
  tone = 'neutral'
}) {
  const t = tones[tone] || tones.neutral;
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      padding: '3px 9px',
      borderRadius: 'var(--radius-sm)',
      fontFamily: 'var(--font-body)',
      fontSize: 'var(--text-caption)',
      fontWeight: 600,
      ...t
    }
  }, children);
}
Object.assign(__ds_scope, { Badge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/feedback/Badge.jsx", error: String((e && e.message) || e) }); }

// components/feedback/Tag.jsx
try { (() => {
function Tag({
  children,
  onRemove,
  color
}) {
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 6,
      padding: '4px 10px',
      borderRadius: 'var(--radius-sm)',
      background: color || 'var(--navy-100)',
      color: 'var(--text-primary)',
      fontFamily: 'var(--font-body)',
      fontSize: 'var(--text-small)',
      fontWeight: 500
    }
  }, children, onRemove && /*#__PURE__*/React.createElement("button", {
    onClick: onRemove,
    "aria-label": "Remove",
    style: {
      border: 'none',
      background: 'transparent',
      cursor: 'pointer',
      color: 'var(--text-tertiary)',
      display: 'flex',
      padding: 0
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: "10",
    height: "10",
    viewBox: "0 0 10 10"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M1 1l8 8M9 1l-8 8",
    stroke: "currentColor",
    strokeWidth: "1.4",
    strokeLinecap: "round"
  }))));
}
Object.assign(__ds_scope, { Tag });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/feedback/Tag.jsx", error: String((e && e.message) || e) }); }

// components/feedback/Toast.jsx
try { (() => {
const icons = {
  success: '✓',
  warning: '!',
  danger: '✕',
  info: 'i'
};
const tones = {
  success: 'var(--state-success)',
  warning: 'var(--state-warning)',
  danger: 'var(--state-danger)',
  info: 'var(--accent-interactive)'
};
function Toast({
  tone = 'info',
  title,
  description,
  onClose
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'flex-start',
      gap: 12,
      padding: '14px 16px',
      width: 320,
      background: 'var(--surface-inverse)',
      borderRadius: 0,
      fontFamily: 'var(--font-body)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 20,
      height: 20,
      borderRadius: '50%',
      background: tones[tone],
      color: 'var(--text-inverse)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontSize: 11,
      flexShrink: 0
    }
  }, icons[tone]), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 'var(--text-body)',
      fontWeight: 600,
      color: 'var(--text-inverse)'
    }
  }, title), description && /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 'var(--text-small)',
      color: 'var(--navy-300)',
      marginTop: 2
    }
  }, description)), onClose && /*#__PURE__*/React.createElement("button", {
    onClick: onClose,
    "aria-label": "Dismiss",
    style: {
      border: 'none',
      background: 'transparent',
      cursor: 'pointer',
      color: 'var(--navy-400)',
      padding: 0
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: "12",
    height: "12",
    viewBox: "0 0 10 10"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M1 1l8 8M9 1l-8 8",
    stroke: "currentColor",
    strokeWidth: "1.4",
    strokeLinecap: "round"
  }))));
}
Object.assign(__ds_scope, { Toast });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/feedback/Toast.jsx", error: String((e && e.message) || e) }); }

// components/feedback/Tooltip.jsx
try { (() => {
const {
  useState
} = React;
function Tooltip({
  children,
  label,
  side = 'top'
}) {
  const [open, setOpen] = useState(false);
  const pos = side === 'top' ? {
    bottom: '100%',
    left: '50%',
    transform: 'translate(-50%,-6px)'
  } : {
    top: '100%',
    left: '50%',
    transform: 'translate(-50%,6px)'
  };
  return /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'relative',
      display: 'inline-flex'
    },
    onMouseEnter: () => setOpen(true),
    onMouseLeave: () => setOpen(false)
  }, children, open && /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      ...pos,
      whiteSpace: 'nowrap',
      padding: '6px 10px',
      borderRadius: 0,
      background: 'var(--surface-inverse)',
      color: 'var(--text-inverse)',
      fontFamily: 'var(--font-body)',
      fontSize: 'var(--text-caption)',
      zIndex: 10
    }
  }, label));
}
Object.assign(__ds_scope, { Tooltip });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/feedback/Tooltip.jsx", error: String((e && e.message) || e) }); }

// components/forms/Button.jsx
try { (() => {
const sizes = {
  sm: {
    padding: '6px 12px',
    fontSize: 'var(--text-small)',
    height: 32
  },
  md: {
    padding: '9px 16px',
    fontSize: 'var(--text-body)',
    height: 40
  },
  lg: {
    padding: '12px 20px',
    fontSize: 'var(--text-body-l)',
    height: 48
  }
};
const variants = {
  primary: {
    background: 'var(--accent-primary)',
    color: 'var(--text-inverse)',
    border: 'none'
  },
  secondary: {
    background: 'transparent',
    color: 'var(--text-primary)',
    border: 'none'
  },
  ghost: {
    background: 'transparent',
    color: 'var(--text-secondary)',
    border: 'none'
  },
  danger: {
    background: 'transparent',
    color: 'var(--state-danger)',
    border: 'none'
  }
};
function Button({
  children,
  variant = 'primary',
  size = 'md',
  icon,
  disabled = false,
  onClick,
  type = 'button'
}) {
  const v = variants[variant] || variants.primary;
  const s = sizes[size] || sizes.md;
  return /*#__PURE__*/React.createElement("button", {
    type: type,
    onClick: disabled ? undefined : onClick,
    disabled: disabled,
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 8,
      justifyContent: 'center',
      fontFamily: 'var(--font-body)',
      fontWeight: 600,
      lineHeight: 1,
      borderRadius: 'var(--radius-sm)',
      cursor: disabled ? 'not-allowed' : 'pointer',
      transition: 'background var(--duration-fast) var(--ease-standard), color var(--duration-fast) var(--ease-standard), opacity var(--duration-fast)',
      opacity: disabled ? 0.45 : 1,
      ...s,
      ...v
    },
    onMouseEnter: e => {
      if (disabled) return;
      if (variant === 'primary') e.currentTarget.style.background = 'var(--navy-800)';else e.currentTarget.style.color = 'var(--text-primary)';
    },
    onMouseLeave: e => {
      if (variant === 'primary') e.currentTarget.style.background = v.background;else e.currentTarget.style.color = v.color;
    }
  }, icon, children);
}
Object.assign(__ds_scope, { Button });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Button.jsx", error: String((e && e.message) || e) }); }

// components/forms/Checkbox.jsx
try { (() => {
function Checkbox({
  checked,
  onChange,
  label,
  disabled = false
}) {
  return /*#__PURE__*/React.createElement("label", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 8,
      cursor: disabled ? 'not-allowed' : 'pointer',
      opacity: disabled ? 0.5 : 1,
      fontFamily: 'var(--font-body)',
      fontSize: 'var(--text-body)',
      color: 'var(--text-primary)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 18,
      height: 18,
      borderRadius: 5,
      border: `1px solid ${checked ? 'var(--accent-primary)' : 'var(--border-default)'}`,
      background: checked ? 'var(--accent-primary)' : 'var(--surface-card)',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      transition: 'background var(--duration-fast) var(--ease-standard), border-color var(--duration-fast) var(--ease-standard)'
    }
  }, checked && /*#__PURE__*/React.createElement("svg", {
    width: "10",
    height: "8",
    viewBox: "0 0 10 8",
    fill: "none"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M1 4l3 3 5-6",
    stroke: "var(--text-inverse)",
    strokeWidth: "1.6",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  }))), /*#__PURE__*/React.createElement("input", {
    type: "checkbox",
    checked: checked,
    onChange: onChange,
    disabled: disabled,
    style: {
      display: 'none'
    }
  }), label);
}
Object.assign(__ds_scope, { Checkbox });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Checkbox.jsx", error: String((e && e.message) || e) }); }

// components/forms/IconButton.jsx
try { (() => {
const sizes = {
  sm: 28,
  md: 36,
  lg: 44
};
function IconButton({
  icon,
  size = 'md',
  variant = 'ghost',
  active = false,
  disabled = false,
  onClick,
  label
}) {
  const dim = sizes[size] || sizes.md;
  const base = variant === 'solid' ? {
    background: 'var(--accent-primary)',
    color: 'var(--text-inverse)',
    border: '1px solid var(--accent-primary)'
  } : {
    background: 'transparent',
    color: active ? 'var(--text-primary)' : 'var(--text-tertiary)',
    border: '1px solid transparent'
  };
  return /*#__PURE__*/React.createElement("button", {
    "aria-label": label,
    onClick: disabled ? undefined : onClick,
    disabled: disabled,
    style: {
      width: dim,
      height: dim,
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      borderRadius: 'var(--radius-sm)',
      cursor: disabled ? 'not-allowed' : 'pointer',
      opacity: disabled ? 0.4 : 1,
      transition: 'color var(--duration-fast) var(--ease-standard)',
      ...base
    },
    onMouseEnter: e => {
      if (!disabled && variant !== 'solid') e.currentTarget.style.color = 'var(--text-primary)';
    },
    onMouseLeave: e => {
      if (variant !== 'solid') e.currentTarget.style.color = active ? 'var(--text-primary)' : 'var(--text-tertiary)';
    }
  }, icon);
}
Object.assign(__ds_scope, { IconButton });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/IconButton.jsx", error: String((e && e.message) || e) }); }

// components/forms/Input.jsx
try { (() => {
function Input({
  placeholder,
  value,
  onChange,
  icon,
  size = 'md',
  error,
  disabled = false,
  type = 'text'
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 6,
      width: '100%'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      padding: '8px 2px',
      borderBottom: `1px solid ${error ? 'var(--state-danger)' : 'var(--border-default)'}`,
      transition: 'border-color var(--duration-fast) var(--ease-standard)'
    },
    onFocus: e => {
      e.currentTarget.style.borderColor = 'var(--text-primary)';
    },
    onBlur: e => {
      e.currentTarget.style.borderColor = error ? 'var(--state-danger)' : 'var(--border-default)';
    }
  }, icon, /*#__PURE__*/React.createElement("input", {
    type: type,
    value: value,
    onChange: onChange,
    placeholder: placeholder,
    disabled: disabled,
    style: {
      flex: 1,
      border: 'none',
      outline: 'none',
      background: 'transparent',
      font: 'inherit',
      fontFamily: 'var(--font-body)',
      fontSize: 'var(--text-body)',
      color: 'var(--text-primary)'
    }
  })), error && /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: 'var(--text-caption)',
      color: 'var(--state-danger)',
      fontFamily: 'var(--font-body)'
    }
  }, error));
}
Object.assign(__ds_scope, { Input });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Input.jsx", error: String((e && e.message) || e) }); }

// components/forms/Radio.jsx
try { (() => {
function Radio({
  checked,
  onChange,
  label,
  name,
  disabled = false
}) {
  return /*#__PURE__*/React.createElement("label", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 8,
      cursor: disabled ? 'not-allowed' : 'pointer',
      opacity: disabled ? 0.5 : 1,
      fontFamily: 'var(--font-body)',
      fontSize: 'var(--text-body)',
      color: 'var(--text-primary)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 18,
      height: 18,
      borderRadius: '50%',
      border: `1px solid ${checked ? 'var(--accent-primary)' : 'var(--border-default)'}`,
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      background: 'var(--surface-card)'
    }
  }, checked && /*#__PURE__*/React.createElement("span", {
    style: {
      width: 9,
      height: 9,
      borderRadius: '50%',
      background: 'var(--accent-primary)'
    }
  })), /*#__PURE__*/React.createElement("input", {
    type: "radio",
    name: name,
    checked: checked,
    onChange: onChange,
    disabled: disabled,
    style: {
      display: 'none'
    }
  }), label);
}
Object.assign(__ds_scope, { Radio });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Radio.jsx", error: String((e && e.message) || e) }); }

// components/forms/Select.jsx
try { (() => {
function Select({
  value,
  onChange,
  options = [],
  size = 'md',
  disabled = false
}) {
  const height = size === 'sm' ? 30 : size === 'lg' ? 42 : 36;
  return /*#__PURE__*/React.createElement("select", {
    value: value,
    onChange: onChange,
    disabled: disabled,
    style: {
      height,
      padding: '0 22px 0 2px',
      borderRadius: 0,
      border: 'none',
      borderBottom: '1px solid var(--border-default)',
      background: 'transparent',
      color: 'var(--text-primary)',
      fontFamily: 'var(--font-body)',
      fontSize: 'var(--text-body)',
      appearance: 'none',
      backgroundImage: "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6'%3E%3Cpath d='M0 0l5 6 5-6z' fill='%2375787F'/%3E%3C/svg%3E\")",
      backgroundRepeat: 'no-repeat',
      backgroundPosition: 'right 2px center',
      cursor: disabled ? 'not-allowed' : 'pointer',
      opacity: disabled ? 0.5 : 1
    }
  }, options.map(o => /*#__PURE__*/React.createElement("option", {
    key: o.value,
    value: o.value
  }, o.label)));
}
Object.assign(__ds_scope, { Select });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Select.jsx", error: String((e && e.message) || e) }); }

// components/forms/Switch.jsx
try { (() => {
function Switch({
  checked,
  onChange,
  disabled = false,
  label
}) {
  return /*#__PURE__*/React.createElement("label", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 10,
      cursor: disabled ? 'not-allowed' : 'pointer',
      opacity: disabled ? 0.5 : 1,
      fontFamily: 'var(--font-body)',
      fontSize: 'var(--text-body)',
      color: 'var(--text-primary)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 36,
      height: 22,
      borderRadius: 'var(--radius-pill)',
      padding: 2,
      background: checked ? 'var(--accent-highlight)' : 'var(--navy-300)',
      display: 'inline-flex',
      alignItems: 'center',
      transition: 'background var(--duration-base) var(--ease-standard)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 18,
      height: 18,
      borderRadius: '50%',
      background: 'var(--white)',
      boxShadow: 'var(--shadow-xs)',
      transform: checked ? 'translateX(14px)' : 'translateX(0)',
      transition: 'transform var(--duration-base) var(--ease-standard)'
    }
  })), /*#__PURE__*/React.createElement("input", {
    type: "checkbox",
    checked: checked,
    onChange: onChange,
    disabled: disabled,
    style: {
      display: 'none'
    }
  }), label);
}
Object.assign(__ds_scope, { Switch });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Switch.jsx", error: String((e && e.message) || e) }); }

// components/navigation/Tabs.jsx
try { (() => {
function Tabs({
  items,
  active,
  onChange
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 4,
      borderBottom: '1px solid var(--border-subtle)',
      fontFamily: 'var(--font-body)'
    }
  }, items.map(it => {
    const isActive = it.value === active;
    return /*#__PURE__*/React.createElement("button", {
      key: it.value,
      onClick: () => onChange(it.value),
      style: {
        padding: '10px 4px',
        marginRight: 20,
        border: 'none',
        background: 'transparent',
        cursor: 'pointer',
        fontSize: 'var(--text-body)',
        fontWeight: 600,
        color: isActive ? 'var(--text-primary)' : 'var(--text-tertiary)',
        borderBottom: `2px solid ${isActive ? 'var(--accent-primary)' : 'transparent'}`,
        transition: 'color var(--duration-fast)'
      }
    }, it.label);
  }));
}
Object.assign(__ds_scope, { Tabs });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/navigation/Tabs.jsx", error: String((e && e.message) || e) }); }

// components/overlay/Dialog.jsx
try { (() => {
function Dialog({
  open,
  title,
  children,
  onClose,
  footer
}) {
  if (!open) return null;
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'fixed',
      inset: 0,
      background: 'rgba(17,19,24,0.35)',
      backdropFilter: 'blur(4px)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      zIndex: 100
    },
    onClick: onClose
  }, /*#__PURE__*/React.createElement("div", {
    onClick: e => e.stopPropagation(),
    style: {
      width: 420,
      maxWidth: '90vw',
      background: 'var(--surface-card)',
      borderRadius: 'var(--radius-lg)',
      boxShadow: 'var(--shadow-lg)',
      overflow: 'hidden'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '20px 24px 8px',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-display)',
      fontSize: 'var(--text-h2)',
      fontWeight: 700,
      color: 'var(--text-primary)'
    }
  }, title), /*#__PURE__*/React.createElement("button", {
    onClick: onClose,
    "aria-label": "Close",
    style: {
      border: 'none',
      background: 'transparent',
      cursor: 'pointer',
      color: 'var(--text-tertiary)'
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: "14",
    height: "14",
    viewBox: "0 0 10 10"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M1 1l8 8M9 1l-8 8",
    stroke: "currentColor",
    strokeWidth: "1.4",
    strokeLinecap: "round"
  })))), /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '8px 24px 20px',
      fontFamily: 'var(--font-body)',
      fontSize: 'var(--text-body)',
      color: 'var(--text-secondary)'
    }
  }, children), footer && /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '0 24px 20px',
      display: 'flex',
      justifyContent: 'flex-end',
      gap: 4
    }
  }, footer)));
}
Object.assign(__ds_scope, { Dialog });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/overlay/Dialog.jsx", error: String((e && e.message) || e) }); }

// ui_kits/web/Composer.jsx
try { (() => {
function Composer({
  open,
  onClose,
  onSend
}) {
  const [sent, setSent] = React.useState(false);
  const [full, setFull] = React.useState(false);
  const [showCc, setShowCc] = React.useState(false);
  const [attachments, setAttachments] = React.useState([]);
  if (!open) return null;
  const F = d => React.createElement('svg', {
    width: 13,
    height: 13,
    viewBox: '0 0 24 24',
    fill: 'none'
  }, React.createElement('path', {
    d,
    stroke: 'currentColor',
    strokeWidth: 1.6,
    strokeLinecap: 'round',
    strokeLinejoin: 'round'
  }));
  const rowStyle = {
    border: 'none',
    outline: 'none',
    borderTop: '1px solid var(--border-subtle)',
    padding: '12px 20px',
    fontFamily: 'var(--font-body)',
    fontSize: 14,
    color: 'var(--text-primary)'
  };
  const fields = React.createElement('div', {
    style: {
      display: 'flex',
      flexDirection: 'column',
      flex: full ? 1 : undefined
    }
  }, React.createElement('div', {
    style: {
      display: 'flex',
      alignItems: 'center'
    }
  }, React.createElement('input', {
    placeholder: 'To',
    style: {
      ...rowStyle,
      border: 'none',
      borderTop: 'none',
      flex: 1
    }
  }), !showCc && React.createElement('button', {
    onClick: () => setShowCc(true),
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: 'var(--text-tertiary)',
      fontFamily: 'var(--font-body)',
      fontSize: 13,
      padding: '0 20px'
    }
  }, 'Cc/Bcc')), showCc && React.createElement('input', {
    placeholder: 'Cc',
    style: {
      ...rowStyle
    }
  }), showCc && React.createElement('input', {
    placeholder: 'Bcc',
    style: {
      ...rowStyle
    }
  }), React.createElement('input', {
    placeholder: 'Subject',
    style: {
      ...rowStyle,
      fontWeight: 600
    }
  }), React.createElement('textarea', {
    placeholder: 'Write your message...',
    rows: full ? 20 : 6,
    style: {
      ...rowStyle,
      resize: 'none',
      flex: full ? 1 : undefined
    }
  }), attachments.length > 0 && React.createElement('div', {
    style: {
      display: 'flex',
      gap: 8,
      flexWrap: 'wrap',
      padding: '0 20px 12px'
    }
  }, attachments.map((a, i) => React.createElement('span', {
    key: i,
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 6,
      padding: '5px 10px',
      border: '1px solid var(--border-subtle)',
      borderRadius: 'var(--radius-md)',
      fontFamily: 'var(--font-body)',
      fontSize: 12.5,
      color: 'var(--text-secondary)'
    }
  }, F('M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9'), a, React.createElement('button', {
    onClick: () => setAttachments(attachments.filter((_, j) => j !== i)),
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: 'var(--text-tertiary)',
      display: 'flex'
    }
  }, F('M6 6l12 12M18 6L6 18'))))), React.createElement('div', {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 14,
      padding: '12px 20px',
      borderTop: '1px solid var(--border-subtle)'
    }
  }, React.createElement('button', {
    onClick: () => {
      setSent(true);
      setTimeout(() => {
        setSent(false);
        setFull(false);
        onSend();
      }, 800);
    },
    title: 'Send',
    style: {
      width: 32,
      height: 32,
      borderRadius: '50%',
      border: 'none',
      background: 'var(--text-primary)',
      color: '#fff',
      cursor: 'pointer',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center'
    }
  }, F('M4 20l1-4L17 4l3 3L8 19l-4 1z')), React.createElement('button', {
    title: 'Send later',
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: 'var(--text-tertiary)',
      display: 'flex'
    }
  }, F('M12 7v5l3 3M12 22a10 10 0 100-20 10 10 0 000 20z')), React.createElement('button', {
    onClick: () => setAttachments([...attachments, 'file-' + (attachments.length + 1) + '.pdf']),
    title: 'Attach file',
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: 'var(--text-tertiary)',
      display: 'flex'
    }
  }, F('M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9'))));
  const body = sent ? React.createElement('div', {
    style: {
      fontFamily: 'var(--font-body)',
      fontSize: 14,
      color: 'var(--text-primary)',
      padding: '0 20px 28px',
      textAlign: 'center'
    }
  }, 'Message sent') : fields;
  if (full) {
    return React.createElement('div', {
      style: {
        position: 'fixed',
        inset: 0,
        background: 'var(--surface-card)',
        zIndex: 55,
        display: 'flex',
        flexDirection: 'column'
      }
    }, React.createElement('div', {
      style: {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '18px 28px'
      }
    }, React.createElement('span', {
      style: {
        fontFamily: 'var(--font-display)',
        fontWeight: 700,
        fontSize: 20,
        color: 'var(--text-primary)'
      }
    }, 'New message'), React.createElement('div', {
      style: {
        display: 'flex',
        gap: 14
      }
    }, React.createElement('button', {
      onClick: () => setFull(false),
      title: 'Collapse',
      style: {
        border: 'none',
        background: 'none',
        cursor: 'pointer',
        color: 'var(--text-tertiary)'
      }
    }, F('M9 3H3v6M15 21h6v-6M21 3l-8 8M3 21l8-8')), React.createElement('button', {
      onClick: () => {
        setSent(false);
        setFull(false);
        onClose();
      },
      style: {
        border: 'none',
        background: 'none',
        cursor: 'pointer',
        color: 'var(--text-tertiary)'
      }
    }, F('M6 6l12 12M18 6L6 18')))), React.createElement('div', {
      style: {
        maxWidth: 720,
        margin: '0 auto',
        width: '100%',
        flex: 1,
        display: 'flex',
        flexDirection: 'column'
      }
    }, body));
  }
  return React.createElement('div', {
    style: {
      position: 'fixed',
      right: 32,
      bottom: 32,
      width: 480,
      background: 'var(--surface-card)',
      border: '1px solid var(--border-subtle)',
      borderRadius: 'var(--radius-lg)',
      boxShadow: 'var(--shadow-lg)',
      zIndex: 50
    }
  }, React.createElement('div', {
    style: {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '14px 20px'
    }
  }, React.createElement('span', {
    style: {
      fontFamily: 'var(--font-body)',
      fontWeight: 600,
      fontSize: 14,
      color: 'var(--text-primary)'
    }
  }, 'New message'), React.createElement('div', {
    style: {
      display: 'flex',
      gap: 12
    }
  }, React.createElement('button', {
    onClick: () => setFull(true),
    title: 'Expand',
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: 'var(--text-tertiary)'
    }
  }, F('M9 3H3v6M15 21h6v-6M21 3l-8 8M3 21l8-8')), React.createElement('button', {
    onClick: () => {
      setSent(false);
      onClose();
    },
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: 'var(--text-tertiary)'
    }
  }, F('M6 6l12 12M18 6L6 18')))), body);
}
window.Composer = Composer;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/web/Composer.jsx", error: String((e && e.message) || e) }); }

// ui_kits/web/InboxList.jsx
try { (() => {
function InboxList({
  emails,
  selectedId,
  onSelect,
  onAction
}) {
  const groups = [{
    label: null,
    items: emails.slice(0, 2)
  }, {
    label: 'Last 7 days',
    items: emails.slice(2)
  }];
  const A = d => React.createElement('svg', {
    width: 15,
    height: 15,
    viewBox: '0 0 24 24',
    fill: 'none'
  }, React.createElement('path', {
    d,
    stroke: 'currentColor',
    strokeWidth: 1.6,
    strokeLinecap: 'round',
    strokeLinejoin: 'round'
  }));
  const actionBtn = (label, d, id) => React.createElement('button', {
    key: label,
    title: label,
    onClick: ev => {
      ev.stopPropagation();
      onAction && onAction(id, label);
    },
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: 'var(--text-tertiary)',
      display: 'flex',
      padding: 4
    },
    onMouseEnter: ev => {
      ev.currentTarget.style.color = 'var(--text-primary)';
    },
    onMouseLeave: ev => {
      ev.currentTarget.style.color = 'var(--text-tertiary)';
    }
  }, A(d));
  return React.createElement('div', null, groups.map((g, gi) => React.createElement('div', {
    key: gi
  }, g.label && React.createElement('div', {
    style: {
      padding: '18px 0 8px',
      fontFamily: 'var(--font-body)',
      fontSize: 12,
      color: 'var(--text-tertiary)'
    }
  }, g.label), g.items.map(e => React.createElement('div', {
    key: e.id,
    onClick: () => onSelect(e.id),
    className: 'vm-row',
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 14,
      width: '100%',
      textAlign: 'left',
      padding: '11px 2px',
      cursor: 'pointer',
      background: selectedId === e.id ? 'var(--surface-sunken)' : 'transparent',
      borderBottom: '1px solid var(--border-subtle)'
    }
  }, React.createElement('span', {
    style: {
      width: 6,
      height: 6,
      borderRadius: '50%',
      background: e.unread ? 'var(--text-primary)' : 'transparent',
      flexShrink: 0
    }
  }), React.createElement('span', {
    style: {
      width: 26,
      height: 26,
      borderRadius: '50%',
      background: 'var(--surface-sunken)',
      color: 'var(--text-secondary)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontFamily: 'var(--font-body)',
      fontSize: 11,
      fontWeight: 600,
      flexShrink: 0
    }
  }, e.from.split(' ').filter(Boolean).slice(0, 2).map(n => n[0].toUpperCase()).join('')), React.createElement('span', {
    style: {
      width: 130,
      flexShrink: 0,
      fontFamily: 'var(--font-body)',
      fontSize: 14,
      fontWeight: e.unread ? 600 : 400,
      color: 'var(--text-primary)',
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      whiteSpace: 'nowrap'
    }
  }, e.from), React.createElement('span', {
    style: {
      fontFamily: 'var(--font-body)',
      fontSize: 14,
      fontWeight: e.unread ? 600 : 400,
      color: 'var(--text-primary)',
      flexShrink: 0,
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      whiteSpace: 'nowrap',
      maxWidth: 220
    }
  }, e.subject), React.createElement('span', {
    style: {
      flex: 1,
      fontFamily: 'var(--font-body)',
      fontSize: 14,
      color: 'var(--text-tertiary)',
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      whiteSpace: 'nowrap'
    }
  }, e.snippet), React.createElement('span', {
    className: 'vm-row-time',
    style: {
      fontFamily: 'var(--font-body)',
      fontSize: 13,
      color: 'var(--text-tertiary)',
      flexShrink: 0
    }
  }, e.time), React.createElement('div', {
    className: 'vm-row-actions',
    style: {
      display: 'none',
      alignItems: 'center',
      gap: 2,
      flexShrink: 0
    }
  }, actionBtn('Done', 'M20 6L9 17l-5-5', e.id), actionBtn('Archive', 'M3 7h18M5 7v12a1 1 0 001 1h12a1 1 0 001-1V7M9 11h6', e.id), actionBtn('Delete', 'M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13', e.id)))))), React.createElement('style', null, '.vm-row:hover .vm-row-actions{display:flex !important}.vm-row:hover .vm-row-time{display:none}'));
}
window.InboxList = InboxList;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/web/InboxList.jsx", error: String((e && e.message) || e) }); }

// ui_kits/web/SearchOverlay.jsx
try { (() => {
function SearchOverlay({
  open,
  onClose
}) {
  if (!open) return null;
  const contacts = [{
    n: 'Priya Nair',
    e: 'priya@vibemail.com'
  }, {
    n: 'Sam Okoye',
    e: 'sam@vibemail.com'
  }, {
    n: 'Ana Torres',
    e: 'ana@vibemail.com'
  }];
  return React.createElement('div', {
    style: {
      position: 'fixed',
      inset: 0,
      background: 'var(--surface-card)',
      zIndex: 60,
      padding: '24px 32px'
    }
  }, React.createElement('div', {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 12,
      borderBottom: '1px solid var(--border-subtle)',
      paddingBottom: 14,
      marginBottom: 20
    }
  }, React.createElement('input', {
    autoFocus: true,
    placeholder: 'Search',
    style: {
      flex: 1,
      border: 'none',
      outline: 'none',
      fontFamily: 'var(--font-body)',
      fontSize: 20,
      color: 'var(--text-primary)'
    }
  }), React.createElement('button', {
    onClick: onClose,
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: 'var(--text-tertiary)'
    }
  }, React.createElement('svg', {
    width: 16,
    height: 16,
    viewBox: '0 0 24 24',
    fill: 'none'
  }, React.createElement('path', {
    d: 'M6 6l12 12M18 6L6 18',
    stroke: 'currentColor',
    strokeWidth: 1.6,
    strokeLinecap: 'round'
  })))), contacts.map((c, i) => React.createElement('div', {
    key: i,
    style: {
      display: 'flex',
      gap: 16,
      padding: '9px 0',
      fontFamily: 'var(--font-body)',
      fontSize: 14
    }
  }, React.createElement('span', {
    style: {
      color: 'var(--text-primary)',
      fontWeight: 500
    }
  }, c.n), React.createElement('span', {
    style: {
      color: 'var(--text-tertiary)'
    }
  }, c.e))));
}
window.SearchOverlay = SearchOverlay;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/web/SearchOverlay.jsx", error: String((e && e.message) || e) }); }

// ui_kits/web/Sidebar.jsx
try { (() => {
function Rail({
  active,
  onSelect,
  onOpenSidebar
}) {
  const Icon = d => React.createElement('svg', {
    width: 17,
    height: 17,
    viewBox: '0 0 24 24',
    fill: 'none'
  }, React.createElement('path', {
    d,
    stroke: 'currentColor',
    strokeWidth: 1.6,
    strokeLinecap: 'round',
    strokeLinejoin: 'round'
  }));
  return React.createElement('div', {
    style: {
      width: 56,
      borderRight: '1px solid var(--border-subtle)',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      padding: '18px 0',
      gap: 18,
      flexShrink: 0
    }
  }, React.createElement('button', {
    onClick: onOpenSidebar,
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: 'var(--text-tertiary)',
      display: 'flex'
    }
  }, Icon('M4 7h16M4 12h16M4 17h16')), React.createElement('div', {
    style: {
      width: 20,
      height: 1,
      background: 'var(--border-subtle)'
    }
  }), React.createElement('button', {
    onClick: () => onSelect('mail'),
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: active === 'mail' ? 'var(--text-primary)' : 'var(--text-tertiary)',
      display: 'flex'
    }
  }, Icon('M3 7l9 6 9-6M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1z')), React.createElement('button', {
    onClick: () => onSelect('calendar'),
    style: {
      border: 'none',
      background: 'none',
      cursor: 'pointer',
      color: active === 'calendar' ? 'var(--text-primary)' : 'var(--text-tertiary)',
      display: 'flex'
    }
  }, Icon('M4 5h16v16H4zM4 9h16M8 3v4M16 3v4')));
}
function Sidebar({
  open,
  active,
  onSelect,
  onClose
}) {
  const items = [{
    key: 'inbox',
    label: 'Inbox'
  }, {
    key: 'starred',
    label: 'Starred'
  }, {
    key: 'sent',
    label: 'Sent'
  }, {
    key: 'drafts',
    label: 'Drafts'
  }, {
    key: 'archive',
    label: 'Archive'
  }];
  return React.createElement(React.Fragment, null, open && React.createElement('div', {
    onClick: onClose,
    style: {
      position: 'fixed',
      inset: 0,
      background: 'rgba(15,23,42,0.15)',
      zIndex: 40
    }
  }), React.createElement('div', {
    style: {
      position: 'fixed',
      top: 0,
      left: 0,
      height: '100%',
      width: 220,
      background: 'var(--surface-card)',
      borderRight: '1px solid var(--border-subtle)',
      display: 'flex',
      flexDirection: 'column',
      padding: '20px 16px',
      gap: 2,
      zIndex: 41,
      transform: open ? 'translateX(0)' : 'translateX(-100%)',
      transition: 'transform var(--duration-base) var(--ease-standard)'
    }
  }, React.createElement('div', {
    style: {
      fontFamily: 'var(--font-display)',
      fontWeight: 700,
      fontSize: 17,
      color: 'var(--text-primary)',
      padding: '0 4px 18px'
    }
  }, 'VibeMail'), items.map(it => React.createElement('button', {
    key: it.key,
    onClick: () => {
      onSelect(it.key);
      onClose();
    },
    style: {
      display: 'flex',
      padding: '8px 8px',
      border: 'none',
      cursor: 'pointer',
      textAlign: 'left',
      background: 'none',
      color: active === it.key ? 'var(--text-primary)' : 'var(--text-secondary)',
      fontFamily: 'var(--font-body)',
      fontSize: 14,
      fontWeight: active === it.key ? 600 : 400
    }
  }, it.label))));
}
window.Rail = Rail;
window.Sidebar = Sidebar;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/web/Sidebar.jsx", error: String((e && e.message) || e) }); }

// ui_kits/web/ThreadView.jsx
try { (() => {
function ThreadView({
  email,
  onClose,
  onReply
}) {
  const {
    IconButton,
    Tooltip,
    Button,
    Tag
  } = window.VibeMailDesignSystem_b5a4d1;
  if (!email) return null;
  const A = d => React.createElement('svg', {
    width: 15,
    height: 15,
    viewBox: '0 0 24 24',
    fill: 'none'
  }, React.createElement('path', {
    d,
    stroke: 'currentColor',
    strokeWidth: 1.6,
    strokeLinecap: 'round',
    strokeLinejoin: 'round'
  }));
  return React.createElement(React.Fragment, null, React.createElement('div', {
    onClick: onClose,
    style: {
      position: 'fixed',
      inset: 0,
      background: 'rgba(15,23,42,0.15)',
      zIndex: 40
    }
  }), React.createElement('div', {
    style: {
      position: 'fixed',
      top: 0,
      right: 0,
      height: '100%',
      width: 460,
      maxWidth: '92vw',
      background: 'var(--surface-card)',
      zIndex: 41,
      display: 'flex',
      flexDirection: 'column',
      borderLeft: '1px solid var(--border-subtle)'
    }
  }, React.createElement('div', {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 4,
      padding: '14px 20px',
      borderBottom: '1px solid var(--border-subtle)'
    }
  }, React.createElement(Tooltip, {
    label: 'Close'
  }, React.createElement(IconButton, {
    icon: A('M15 18l-6-6 6-6'),
    label: 'Close',
    onClick: onClose
  })), React.createElement('div', {
    style: {
      flex: 1
    }
  }), React.createElement(Tooltip, {
    label: 'Archive'
  }, React.createElement(IconButton, {
    icon: A('M3 7h18M5 7v12a1 1 0 001 1h12a1 1 0 001-1V7M9 11h6'),
    label: 'Archive'
  })), React.createElement(Tooltip, {
    label: 'Delete'
  }, React.createElement(IconButton, {
    icon: A('M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13'),
    label: 'Delete'
  }))), React.createElement('div', {
    style: {
      padding: '28px 28px',
      overflowY: 'auto',
      flex: 1
    }
  }, React.createElement('h1', {
    style: {
      fontFamily: 'var(--font-display)',
      fontSize: 21,
      fontWeight: 700,
      color: 'var(--text-primary)',
      margin: '0 0 6px'
    }
  }, email.subject), React.createElement('div', {
    style: {
      fontFamily: 'var(--font-body)',
      fontSize: 13,
      color: 'var(--text-tertiary)',
      marginBottom: 24
    }
  }, email.from, ' · to me · ', email.time), React.createElement('div', {
    style: {
      fontFamily: 'var(--font-body)',
      fontSize: 15,
      lineHeight: 1.6,
      color: 'var(--text-secondary)'
    }
  }, email.body), React.createElement('div', {
    style: {
      marginTop: 28,
      display: 'flex',
      gap: 4
    }
  }, React.createElement(Tooltip, {
    label: 'Reply'
  }, React.createElement(IconButton, {
    icon: A('M9 17l-5-5 5-5M4 12h11a5 5 0 010 10h-1'),
    label: 'Reply',
    onClick: onReply
  })), React.createElement(Tooltip, {
    label: 'Reply all'
  }, React.createElement(IconButton, {
    icon: A('M13 17l-5-5 5-5M6 17l-5-5 5-5M1 12h14a5 5 0 010 10h-1'),
    label: 'Reply all',
    onClick: onReply
  })), React.createElement(Tooltip, {
    label: 'Forward'
  }, React.createElement(IconButton, {
    icon: A('M15 17l5-5-5-5M20 12H9a5 5 0 000 10h1'),
    label: 'Forward'
  }))))));
}
window.ThreadView = ThreadView;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/web/ThreadView.jsx", error: String((e && e.message) || e) }); }

__ds_ns.Avatar = __ds_scope.Avatar;

__ds_ns.Card = __ds_scope.Card;

__ds_ns.Badge = __ds_scope.Badge;

__ds_ns.Tag = __ds_scope.Tag;

__ds_ns.Toast = __ds_scope.Toast;

__ds_ns.Tooltip = __ds_scope.Tooltip;

__ds_ns.Button = __ds_scope.Button;

__ds_ns.Checkbox = __ds_scope.Checkbox;

__ds_ns.IconButton = __ds_scope.IconButton;

__ds_ns.Input = __ds_scope.Input;

__ds_ns.Radio = __ds_scope.Radio;

__ds_ns.Select = __ds_scope.Select;

__ds_ns.Switch = __ds_scope.Switch;

__ds_ns.Tabs = __ds_scope.Tabs;

__ds_ns.Dialog = __ds_scope.Dialog;

})();
