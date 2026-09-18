import unittest

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'dashboard'))

from app import app


class DashboardRefreshRouteTest(unittest.TestCase):
    def test_refresh_route_exists(self):
        routes = {route.path for route in app.routes}
        self.assertIn('/refresh', routes)


if __name__ == '__main__':
    unittest.main()
