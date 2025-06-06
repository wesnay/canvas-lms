/*
 * Copyright (C) 2021 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import config from '../config'
import {useScope as createI18nScope} from '@canvas/i18n'
import parseNumber from './parse_number'

const I18n = createI18nScope('quiz_statistics')

export default function formatNumber(n, precision) {
  if (precision === undefined) {
    precision = config.precision
  }

  if (typeof n !== 'number' || !(n instanceof Number)) {
    n = parseNumber(n)
  }

  return I18n.n(n.toFixed(parseInt(precision, 10)))
}
